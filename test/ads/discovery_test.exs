defmodule ADS.DiscoveryTest do
  use ExUnit.Case, async: true

  alias ADS.{Client, Discovery}
  alias ADS.Test.{FakeDiscovery, FakePLC}

  setup do
    fake = start_supervised!(FakeDiscovery)
    %{fake: fake, port: FakeDiscovery.port(fake)}
  end

  test "a datagram is bytes, in order, little-endian" do
    datagram = %{service: 6, net_id: <<10, 0, 0, 7, 1, 1>>, port: 0, tags: [{2, "1" <> <<0>>}]}
    bytes = Discovery.encode(datagram)

    assert bytes ==
             <<0x71146603::32-little, 0::32, 6::32-little, 10, 0, 0, 7, 1, 1, 0::16, 1::32-little,
               2::16-little, 2::16-little, ?1, 0>>

    assert Discovery.decode(bytes) == {:ok, Map.put(datagram, :invoke_id, 0)}
  end

  test "tags are read as far as they go, and as many as there are said to be" do
    head = <<0x71146603::32-little, 0::32, 0x80000001::32-little, 0::48, 0::16>>
    tag = <<5::16-little, 2::16-little, "ab">>

    assert {:ok, %{tags: [{5, "ab"}]}} = Discovery.decode(head <> <<9::32-little>> <> tag <> "x")
    assert {:ok, %{tags: [{5, "ab"}]}} = Discovery.decode(head <> <<1::32-little>> <> tag <> tag)
    assert {:ok, %{tags: []}} = Discovery.decode(head)
    assert Discovery.decode(<<0x71146604::32-little>> <> binary_part(head, 4, 16)) == :error
    assert Discovery.decode("") == :error
  end

  test "a device's info", %{port: port} do
    assert {:ok, device} = Discovery.info("127.0.0.1", port: port)
    assert device.address == {127, 0, 0, 1}
    assert device.net_id == "5.36.69.176.1.1"
    assert device.name == "CX-FAKE"
    assert device.version == {3, 1, 4026}

    assert device.fingerprint ==
             "E3:B0:C4:42:98:FC:1C:14:9A:FB:F4:C8:99:6F:B9:24:" <>
               "27:AE:41:E4:64:9B:93:4C:A4:95:99:1B:78:52:B8:55"

    assert {3, <<3, 1, 4026::16-little>>} in device.tags
  end

  test "a search, of the addresses asked, gives each device that answers", %{
    fake: fake,
    port: port
  } do
    assert {:ok, [%{net_id: "5.36.69.176.1.1"}]} =
             Discovery.search(to: ["127.0.0.1"], port: port, timeout: 200)

    :ok = FakeDiscovery.set(fake, :mode, :twice)

    assert {:ok, [%{net_id: "5.36.69.176.1.1"}, %{net_id: "10.0.0.9.1.1"}]} =
             Discovery.search(to: [{127, 0, 0, 1}], port: port, timeout: 200)

    :ok = FakeDiscovery.set(fake, :mode, :silent)
    assert Discovery.search(to: ["127.0.0.1"], port: port, timeout: 100) == {:ok, []}
  end

  test "a search passes over what isn't an answer", %{fake: fake, port: port} do
    :ok = FakeDiscovery.set(fake, :mode, :junk_first)

    assert {:ok, [%{net_id: "5.36.69.176.1.1"}]} =
             Discovery.search(to: ["127.0.0.1"], port: port, timeout: 200)
  end

  test "a route, for the client's address and NetId by default", %{fake: fake, port: port} do
    assert Discovery.add_route("127.0.0.1", password: "1", port: port) == :ok

    assert FakeDiscovery.routes(fake) == [
             %{
               name: "127.0.0.1",
               net_id: "127.0.0.1.1.1",
               address: "127.0.0.1",
               user: "Administrator"
             }
           ]
  end

  test "a route as asked for", %{fake: fake, port: port} do
    :ok = FakeDiscovery.set(fake, :user, "guest")

    assert Discovery.add_route({127, 0, 0, 1},
             user: "guest",
             password: "1",
             net_id: "10.0.0.7.1.1",
             address: "scada",
             name: "SCADA",
             port: port
           ) == :ok

    assert [%{name: "SCADA", net_id: "10.0.0.7.1.1", address: "scada", user: "guest"}] =
             FakeDiscovery.routes(fake)
  end

  test "a wrong password is the device's error", %{fake: fake, port: port} do
    assert Discovery.add_route("127.0.0.1", password: "2", port: port) ==
             {:error, :device_invalid_access}

    assert FakeDiscovery.routes(fake) == []
  end

  test "a PLC closes on a client it has no route for, until one is added, and lets it in then" do
    plc = start_supervised!({FakePLC, routes: []})
    udp = start_supervised!({FakeDiscovery, plc: plc}, id: :udp)

    client =
      start_supervised!(
        {Client,
         host: "127.0.0.1", port: FakePLC.port(plc), net_id: "5.36.69.176.1.1", backoff: {10, 20}}
      )

    assert Client.read_state(client) == {:error, :closed}
    assert Client.read_state(client) == {:error, :closed}
    assert Discovery.add_route("127.0.0.1", password: "1", port: FakeDiscovery.port(udp)) == :ok
    assert run?(client, 100)
  end

  test "a route deleted, with the login, as one is added: the PLC lets the client in no more" do
    plc = start_supervised!({FakePLC, routes: []})
    udp = start_supervised!({FakeDiscovery, plc: plc}, id: :udp)
    port = FakeDiscovery.port(udp)
    assert Discovery.add_route("127.0.0.1", password: "1", port: port) == :ok
    assert [%{net_id: "127.0.0.1.1.1"}] = FakeDiscovery.routes(udp)

    assert Discovery.delete_route("127.0.0.1", password: "2", port: port) ==
             {:error, :device_invalid_access}

    assert [_still] = FakeDiscovery.routes(udp)
    assert Discovery.delete_route("127.0.0.1", password: "1", port: port) == :ok
    assert FakeDiscovery.routes(udp) == []

    assert Discovery.delete_route("127.0.0.1", password: "1", port: port) ==
             {:error, :device_not_found}

    client =
      start_supervised!(
        {Client, host: "127.0.0.1", port: FakePLC.port(plc), net_id: "5.36.69.176.1.1"}
      )

    assert Client.read_state(client) == {:error, :closed}
    assert_raise ArgumentError, ~r/password/, fn -> Discovery.delete_route("127.0.0.1", []) end

    # By its name: another route of the same NetId stays, and lets the client in.
    for name <- ["plain", "secure"],
        do: :ok = Discovery.add_route("127.0.0.1", password: "1", port: port, name: name)

    assert Discovery.delete_route("127.0.0.1", password: "1", port: port, name: "secure") == :ok
    assert [%{name: "plain"}] = FakeDiscovery.routes(udp)
    assert run?(client, 200)
  end

  defp run?(client, tries) do
    case Client.read_state(client) do
      {:ok, %{ads_state: :run}} -> true
      _not_yet when tries > 0 -> Process.sleep(10) && run?(client, tries - 1)
      _ -> false
    end
  end

  test "an answer comes through junk, from the device and elsewhere", %{fake: fake, port: port} do
    :ok = FakeDiscovery.set(fake, :mode, :junk_first)
    assert Discovery.add_route("127.0.0.1", password: "1", port: port) == :ok
  end

  test "no answer, or one without a result", %{fake: fake, port: port} do
    :ok = FakeDiscovery.set(fake, :mode, :silent)

    assert Discovery.add_route("127.0.0.1", password: "1", port: port, timeout: 100) ==
             {:error, :timeout}

    assert Discovery.info("127.0.0.1", port: port, timeout: 100) == {:error, :timeout}

    :ok = FakeDiscovery.set(fake, :mode, :no_result)

    assert {:error, {:invalid_response, data}} =
             Discovery.add_route("127.0.0.1", password: "1", port: port)

    assert {:ok, %{tags: [{3, "x"}]}} = Discovery.decode(data)
  end

  test "nothing there" do
    {:ok, socket} = :gen_udp.open(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)

    assert {:error, reason} = Discovery.info("127.0.0.1", port: port, timeout: 200)
    assert reason in [:econnrefused, :timeout]
    assert {:error, _} = Discovery.info("no-such-host.invalid")
  end

  test "options that don't make sense raise" do
    assert_raise ArgumentError, ~r/password/, fn -> Discovery.add_route("127.0.0.1", []) end
    assert_raise ArgumentError, ~r/unknown/, fn -> Discovery.search(bogus: 1) end
    assert_raise ArgumentError, ~r/timeout/, fn -> Discovery.info("127.0.0.1", timeout: 0) end
    assert_raise ArgumentError, ~r/port/, fn -> Discovery.info("127.0.0.1", port: 70_000) end
    assert_raise ArgumentError, fn -> Discovery.info(:nowhere) end

    assert_raise ArgumentError, ~r/Windows-1252/, fn ->
      Discovery.add_route("127.0.0.1", password: "日本")
    end
  end
end
