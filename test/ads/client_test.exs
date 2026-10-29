defmodule ADS.ClientTest do
  use ExUnit.Case, async: true

  alias ADS.{AMS, Client, Command}
  alias ADS.Test.FakePLC

  # A router played by the test, a packet at a time, to answer as no PLC would.
  import ADS.Test.Hostile,
    only: [listen: 0, accept: 1, next_packet: 1, next_packet: 2, answer: 3, answer: 4]

  @net_id "5.36.69.176.1.1"

  defp plc(opts \\ []), do: start_supervised!({FakePLC, opts}, id: make_ref())

  defp client(plc, opts \\ []) do
    opts =
      Keyword.merge(
        [host: "127.0.0.1", port: FakePLC.port(plc), net_id: @net_id, timeout: 1000],
        opts
      )

    start_supervised!({Client, opts}, id: make_ref())
  end

  # The commands the PLC got, and the index groups of reads, writes and read-writes.
  defp requests(plc) do
    for {command, data} <- FakePLC.requests(plc) do
      case {command, data} do
        {command, <<group::32-little, _::binary>>} when command in [2, 3, 9] -> {command, group}
        {command, _} -> command
      end
    end
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else: Process.sleep(10) && eventually(fun, tries - 1)
  end

  @values %{
    "MAIN.nCounter" => -5,
    "MAIN.nSpeed" => 1500,
    "MAIN.bOn" => true,
    "MAIN.fTemp" => 21.5,
    "MAIN.sName" => "Pump 1",
    "MAIN.wsText" => "Grüße",
    "MAIN.aValues" => [1, 2, 3, 4, 5],
    "MAIN.stPump" => %{
      "nSpeed" => 7,
      "fTemp" => -1.5,
      "bRunning" => true,
      "eMode" => "eAuto",
      "sTag" => "P1"
    },
    "MAIN.aPumps" => [
      %{"nSpeed" => 1, "fTemp" => 1.0, "bRunning" => false, "eMode" => "eOff", "sTag" => "A"},
      %{"nSpeed" => 2, "fTemp" => 2.0, "bRunning" => true, "eMode" => "eManual", "sTag" => "B"}
    ],
    "MAIN.eMode" => "eManual",
    "MAIN.tDelay" => 2500,
    "MAIN.dtStamp" => ~N[2026-10-28 12:00:00],
    "MAIN.sText" =>
      "a text longer than eighty characters, which T_MaxString holds, being a STRING(255) by another name",
    "MAIN.stFlags" => %{"bA" => false, "bB" => true, "nRest" => 7},
    "GVL.sUtf8" => "€uro, ½"
  }

  test "the device's name, version and state, and stopping and starting it" do
    plc = plc()
    client = client(plc)
    assert Client.read_device_info(client) == {:ok, %{name: "Plc30 App", version: {3, 1, 4026}}}
    assert Client.read_state(client) == {:ok, %{ads_state: :run, device_state: 0}}
    assert Client.write_control(client, :stop) == :ok
    assert Client.read_state(client) == {:ok, %{ads_state: :stop, device_state: 0}}
    assert Client.write_control(client, :run, device_state: 0, data: <<>>) == :ok
    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
  end

  test "a variable of each type, written and read back by name, as the PLC describes it" do
    plc = plc()
    client = client(plc)

    for {name, value} <- @values do
      assert Client.write(client, name, value) == :ok, name
      assert Client.read(client, name) == {:ok, value}, name
      assert FakePLC.get(plc, name) == value, name
    end
  end

  test "a name is looked up once, its handle and its type kept; with type: its type isn't asked for" do
    plc = plc()
    client = client(plc)
    assert {:ok, _} = Client.read(client, "MAIN.stPump")
    assert {:ok, _} = Client.read(client, "MAIN.stPump")

    assert requests(plc) == [
             {9, 0xF009},
             {9, 0xF011},
             {9, 0xF011},
             {9, 0xF003},
             {2, 0xF005},
             {2, 0xF005}
           ]

    plc = plc()
    client = client(plc)
    assert Client.read(client, "MAIN.nSpeed", type: :int) == {:ok, 0}
    assert Client.read(client, "MAIN.nSpeed") == {:ok, 0}
    assert requests(plc) == [{9, 0xF003}, {2, 0xF005}, {9, 0xF009}, {2, 0xF005}]
    assert {:ok, {:struct, _, _} = pump} = Client.type(client, "ST_Pump")
    assert pump == FakePLC.pump()
  end

  test "a description a type needs that doesn't come is an error, and it's looked up again" do
    plc = plc()
    :ok = FakePLC.put(plc, "MAIN.stPump", @values["MAIN.stPump"])
    :ok = FakePLC.set(plc, :mute, "E_Mode")
    client = client(plc, timeout: 200)
    # E_Mode's description doesn't come, rather than eMode being a number, kept for good
    assert Client.read(client, "MAIN.stPump") == {:error, :timeout}
    assert {:ok, %{"eMode" => "eAuto", "nSpeed" => 7}} = Client.read(client, "MAIN.stPump")
    assert {:ok, {:struct, _, _}} = Client.type(client, "ST_Pump")
    :ok = FakePLC.set(plc, :mute, "E_Mode")
    client = client(plc, timeout: 200)
    assert Client.type(client, "ST_Pump") == {:error, :timeout}
    assert {:ok, {:struct, _, _}} = Client.type(client, "ST_Pump")
  end

  test "by index group and offset, with a type" do
    client = client(plc())
    type = {:array, :int, [{1, 3}]}
    assert Client.write(client, {0x4020, 4}, [1, -2, 3], type: type) == :ok
    assert Client.read(client, {0x4020, 4}, type: type) == {:ok, [1, -2, 3]}
    assert Client.read(client, {0x4020, 4}, type: :udint) == {:ok, 0xFFFE0001}
    assert Client.read(client, {0x4020, 4}, type: :dint) == {:ok, -0x1FFFF}
    assert Client.read(client, {0x4020, 5000}, type: :int) == {:error, :device_invalid_offset}
    assert_raise ArgumentError, fn -> Client.read(client, {0x4020, 4}) end
    assert_raise ArgumentError, fn -> Client.read(client, {0x4020, 4}, type: :nope) end
    assert_raise ArgumentError, fn -> Client.read(client, :nowhere) end
  end

  test "the errors of a PLC, and of a router, for names, ports and systems it hasn't" do
    plc = plc()
    client = client(plc)
    assert Client.read(client, "MAIN.nNone") == {:error, :device_symbol_not_found}
    assert Client.read(client, "MAIN.nSpeed", port: 852) == {:error, :target_port_not_found}
    assert Client.read_state(client, port: 10_000) == {:error, :target_port_not_found}
    other = client(plc, net_id: "1.2.3.4.5.6")
    assert Client.read_state(other) == {:error, :target_machine_not_found}
    assert Client.request(client, {:read, 0x1234, 0, 1}) == {:error, :device_invalid_group}
  end

  test "a value that doesn't fit raises in the caller, and nothing is written" do
    plc = plc()
    client = client(plc)
    assert_raise ArgumentError, fn -> Client.write(client, "MAIN.nSpeed", 70_000) end
    assert_raise ArgumentError, fn -> Client.write(client, "MAIN.stPump", %{"nSpeed" => 1}) end

    assert_raise ArgumentError, fn ->
      Client.write_many(client, [{"MAIN.nCounter", 1}, {"MAIN.nSpeed", "fast"}])
    end

    assert FakePLC.get(plc, "MAIN.nCounter") == 0
    refute Enum.any?(requests(plc), &match?({_, 0xF081}, &1))
  end

  test "many at once, in sum commands, each with its own result, in order" do
    plc = plc()
    client = client(plc)

    assert Client.write_many(client, [
             {"MAIN.nCounter", 42},
             {"MAIN.nNone", 1},
             {"MAIN.sName", "Tank", {:string, 20}},
             {{0x4020, 0}, 7, :dint}
           ]) == {:ok, [:ok, {:error, :device_symbol_not_found}, :ok, :ok]}

    assert Client.read_many(client, [
             "MAIN.nCounter",
             "MAIN.nNone",
             {"MAIN.sName", {:string, 20}},
             {{0x4020, 0}, :dint},
             "MAIN.stPump"
           ]) ==
             {:ok,
              [
                {:ok, 42},
                {:error, :device_symbol_not_found},
                {:ok, "Tank"},
                {:ok, 7},
                {:ok,
                 %{
                   "nSpeed" => 0,
                   "fTemp" => 0.0,
                   "bRunning" => false,
                   "eMode" => "eOff",
                   "sTag" => ""
                 }}
              ]}

    assert {9, 0xF080} in requests(plc)
    assert {9, 0xF081} in requests(plc)
    # the handles in a sum command too
    assert {9, 0xF082} in requests(plc)
  end

  test "more than 500 go in several sum commands" do
    plc = plc()
    client = client(plc)
    targets = for offset <- 0..599, do: {{0x4020, offset}, :usint}
    assert {:ok, results} = Client.read_many(client, targets)
    assert results == List.duplicate({:ok, 0}, 600)
    assert Enum.count(requests(plc), &(&1 == {9, 0xF080})) == 2
  end

  test "a device without sum commands is asked one at a time" do
    plc = plc(sum: false)
    client = client(plc)

    assert Client.write_many(client, [{"MAIN.nCounter", 5}, {"MAIN.bOn", true}]) ==
             {:ok, [:ok, :ok]}

    assert Client.read_many(client, ["MAIN.nCounter", "MAIN.bOn"]) ==
             {:ok, [{:ok, 5}, {:ok, true}]}

    assert {2, 0xF005} in requests(plc)
  end

  test "the PLC's descriptions of all its variables and types, and of one by name" do
    client = client(plc())
    assert {:ok, symbols} = Client.symbols(client)
    assert Enum.map(symbols, & &1.name) == Enum.map(FakePLC.variables(), &elem(&1, 0))

    assert %ADS.Symbol{type: "ST_Pump", index_group: 0x4040, data_type: :big_type} =
             Enum.find(symbols, &(&1.name == "MAIN.stPump"))

    assert {:ok, types} = Client.data_types(client)
    assert "E_Mode" in Enum.map(types, & &1.name)

    assert {:ok, %ADS.Symbol{name: "MAIN.nSpeed", type: "INT", size: 2}} =
             Client.symbol(client, "MAIN.nSpeed")

    assert {:ok, %ADS.DataType{name: "T_MaxString", size: 256}} =
             Client.data_type(client, "T_MaxString")

    assert Client.symbol(client, "MAIN.nNone") == {:error, :device_symbol_not_found}
  end

  test "notifications on change: the value at once, then each change, and none after unsubscribing" do
    plc = plc()
    client = client(plc)
    assert {:ok, ref} = Client.subscribe(client, ["MAIN.nSpeed", "MAIN.stPump"])
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 0, %DateTime{}}}
    assert_receive {Client, ^ref, {:value, "MAIN.stPump", %{"nSpeed" => 0}, %DateTime{}}}
    :ok = FakePLC.put(plc, "MAIN.nSpeed", 1200)
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 1200, _}}
    refute_receive {Client, ^ref, {:value, "MAIN.stPump", _, _}}, 50
    assert FakePLC.notifications(plc) == 2
    assert Client.unsubscribe(client, ref) == :ok
    eventually(fn -> FakePLC.notifications(plc) == 0 end)
    :ok = FakePLC.put(plc, "MAIN.nSpeed", 1300)
    refute_receive {Client, ^ref, _}, 50
  end

  test "cyclic notifications, by name or address, to another process" do
    plc = plc()
    client = client(plc)
    test = self()

    assert {:ok, ref} =
             Client.subscribe(client, {{0x4020, 0}, :dint},
               mode: :cyclic,
               cycle_time: 20,
               to: test
             )

    for _ <- 1..3, do: assert_receive({Client, ^ref, {:value, {0x4020, 0}, 0, _}}, 500)

    # A name looked up for another process: the values go to it, and nothing else does.
    other = spawn_link(fn -> relay(test) end)
    assert {:ok, ref} = Client.subscribe(client, "MAIN.stPump", to: other)
    assert_receive {:relayed, {Client, ^ref, {:value, "MAIN.stPump", %{"nSpeed" => 0}, _}}}
    :ok = Client.unsubscribe(client, ref)
    refute_receive {:relayed, _}, 100

    assert_raise ArgumentError, fn ->
      Client.subscribe(client, "MAIN.nSpeed", mode: :sometimes)
    end

    assert_raise ArgumentError, fn -> Client.subscribe(client, "MAIN.nSpeed", cycle_time: -1) end
    assert Client.subscribe(client, "MAIN.nNone") == {:error, :device_symbol_not_found}
  end

  defp relay(to) do
    receive do
      message -> send(to, {:relayed, message}) && relay(to)
    end
  end

  test "a subscription ends when its subscriber does" do
    plc = plc()
    client = client(plc)

    subscriber =
      spawn(fn ->
        {:ok, _ref} = Client.subscribe(client, "MAIN.nSpeed")

        receive do
          :stop -> :ok
        end
      end)

    eventually(fn -> FakePLC.notifications(plc) == 1 end)
    send(subscriber, :stop)
    eventually(fn -> FakePLC.notifications(plc) == 0 end)
  end

  test "after an online change, handles are looked up again, and notifications added again" do
    plc = plc()
    client = client(plc)
    assert {:ok, 0} = Client.read(client, "MAIN.nSpeed")
    assert {:ok, ref} = Client.subscribe(client, "MAIN.nCounter")
    assert_receive {Client, ^ref, {:value, "MAIN.nCounter", 0, _}}

    :ok = FakePLC.online_change(plc)
    :ok = FakePLC.put(plc, "MAIN.nSpeed", 9)
    assert Client.read(client, "MAIN.nSpeed") == {:ok, 9}
    assert Client.read_many(client, ["MAIN.nSpeed"]) == {:ok, [{:ok, 9}]}

    # added again, with the value as it is then
    assert_receive {Client, ^ref, {:value, "MAIN.nCounter", 0, _}}
    :ok = FakePLC.put(plc, "MAIN.nCounter", 3)
    assert_receive {Client, ^ref, {:value, "MAIN.nCounter", 3, _}}
  end

  test "when the connection drops, subscribers hear of it, and the values come again once it's back" do
    plc = plc()
    client = client(plc, backoff: {10, 50})
    assert {:ok, ref} = Client.subscribe(client, "MAIN.nSpeed")
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 0, _}}

    :ok = FakePLC.drop_connections(plc)
    assert_receive {Client, ^ref, {:disconnected, :closed}}
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 0, _}}, 1000
    :ok = FakePLC.put(plc, "MAIN.nSpeed", 5)
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 5, _}}
    assert Client.read(client, "MAIN.nSpeed") == {:ok, 5}
    assert Client.status(client) == :connected
  end

  test "stopping the client lets go of its handles and notifications" do
    plc = plc()
    opts = [host: "127.0.0.1", port: FakePLC.port(plc), net_id: @net_id]
    client = start_supervised!({Client, opts}, restart: :temporary)
    assert {:ok, _} = Client.read_many(client, ["MAIN.nSpeed", "MAIN.bOn", "MAIN.fTemp"])
    assert {:ok, _ref} = Client.subscribe(client, "MAIN.nCounter")
    assert FakePLC.handles(plc) == 4
    assert FakePLC.notifications(plc) == 1
    :ok = Client.stop(client)
    eventually(fn -> FakePLC.handles(plc) == 0 and FakePLC.notifications(plc) == 0 end)
  end

  test "the client's NetId is its address with .1.1, or the one given; and its port one of a client's" do
    plc = plc()
    client = client(plc)
    assert {:ok, _} = Client.read_state(client)

    assert %{status: :connected, local: {"127.0.0.1.1.1", port}, remote: {@net_id, 851}} =
             Client.info(client)

    assert port in 32768..65535

    client = client(plc, local_net_id: "10.0.0.7.1.1", local_ams_port: 40_000, ams_port: 851)
    assert {:ok, _} = Client.read_state(client)
    assert %{local: {"10.0.0.7.1.1", 40_000}} = Client.info(client)
  end

  test "requests while there's no connection fail at once, and status says why" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    client = start_supervised!({Client, host: "127.0.0.1", port: port, net_id: @net_id})
    eventually(fn -> Client.status(client) == {:disconnected, :econnrefused} end)
    assert Client.read_state(client) == {:error, :closed}
  end

  test "options that don't make sense raise" do
    for opts <- [
          [net_id: @net_id],
          [host: "plc"],
          [host: "plc", net_id: "5.36"],
          [host: "plc", net_id: @net_id, port: 70_000],
          [host: "plc", net_id: @net_id, ams_port: -1],
          [host: "plc", net_id: @net_id, timeout: 0],
          [host: "plc", net_id: @net_id, backoff: {10, 5}],
          [host: "plc", net_id: @net_id, flying: true],
          [host: "plc", net_id: @net_id, secure: [psk: :nope]],
          [host: "plc", net_id: @net_id, secure: []],
          [host: 42, net_id: @net_id]
        ] do
      assert_raise ArgumentError, fn -> Client.start_link(opts) end
    end

    {:ok, client} =
      Client.start_link(host: "localhost", net_id: @net_id, port: 1, name: :ads_named_client)

    assert Process.whereis(:ads_named_client) == client
    assert_raise ArgumentError, fn -> Client.request(client, :read_everything) end
    assert_raise ArgumentError, fn -> Client.request(client, :read_state, timeout: -1) end
    assert_raise ArgumentError, fn -> Client.request(client, :read_state, port: 70_000) end
    Client.stop(client)
  end

  defp scripted(port, opts \\ []) do
    start_supervised!(
      {Client, [host: "127.0.0.1", port: port, net_id: @net_id, timeout: 500] ++ opts},
      id: make_ref()
    )
  end

  test "several requests on the way at once, up to max_pending, answered in any order" do
    {listen, port} = listen()
    client = scripted(port, max_pending: 3)
    refs = for i <- 0..4, do: Client.send_request(client, {:read, 0x4020, i, 1})
    socket = accept(listen)

    first = for _ <- 1..3, do: next_packet(socket)
    assert next_packet(socket, 100) == {:error, :timeout}

    for packet <- Enum.reverse(first) do
      <<_::32, offset::32-little, _::32>> = packet.data
      answer(socket, packet, <<0::32, 1::32-little, offset + 100>>)
    end

    rest = for _ <- 1..2, do: next_packet(socket)

    for packet <- rest do
      <<_::32, offset::32-little, _::32>> = packet.data
      answer(socket, packet, <<0::32, 1::32-little, offset + 100>>)
    end

    for {ref, i} <- Enum.with_index(refs) do
      expected = i + 100
      assert_receive {Client, ^ref, {:ok, <<^expected>>}}
    end

    assert (first ++ rest) |> Enum.map(& &1.invoke_id) |> Enum.uniq() |> length() == 5
  end

  test "an answer must be to the command its invoke id was, and its AMS error is the result" do
    {listen, port} = listen()
    client = scripted(port)
    task = Task.async(fn -> Client.read_state(client) end)
    socket = accept(listen)
    packet = next_packet(socket)
    answer(socket, packet, <<0::32, 5::16-little, 0::16>>, command: 2)
    assert Task.await(task) == {:error, :timeout}

    task = Task.async(fn -> Client.read_state(client) end)
    packet = next_packet(socket)
    answer(socket, packet, <<>>, error_code: 0x7)
    assert Task.await(task) == {:error, :target_machine_not_found}
  end

  test "two requests in a row that time out with nothing heard mean the connection is dead" do
    {listen, port} = listen()
    client = scripted(port, timeout: 100, backoff: {10, 10})
    socket = accept(listen)
    assert Client.read_state(client) == {:error, :timeout}
    assert Client.read_state(client) == {:error, :timeout}
    # a new connection, the old one closed after the two requests
    new = accept(listen)
    assert %AMS{command: 4} = next_packet(socket)
    assert %AMS{command: 4} = next_packet(socket)
    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}
    task = Task.async(fn -> Client.read_state(client) end)
    packet = next_packet(new)
    answer(new, packet, <<0::32, 5::16-little, 0::16>>)
    assert Task.await(task) == {:ok, %{ads_state: :run, device_state: 0}}
  end

  test "a request sent to the client is answered as one it doesn't support" do
    {listen, port} = listen()
    client = scripted(port, local_net_id: "10.0.0.7.1.1", local_ams_port: 33_000)
    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    packet = next_packet(socket)

    request = %AMS{
      target: packet.source,
      target_port: 33_000,
      source: packet.target,
      source_port: 851,
      command: 2,
      invoke_id: 99,
      data: <<0::96>>
    }

    :ok = :gen_tcp.send(socket, AMS.encode(request))

    assert %AMS{command: 2, invoke_id: 99, error_code: 0x701, state_flags: 5, target_port: 851} =
             next_packet(socket)

    answer(socket, packet, <<0::32, 5::16-little, 0::16>>)
    assert {:ok, _} = Task.await(task)
  end

  test "a notification is one even flagged as a response, as some devices send them" do
    {listen, port} = listen()
    client = scripted(port)
    socket = accept(listen)
    test = self()
    task = Task.async(fn -> Client.subscribe(client, {{0x4020, 0}, :dint}, to: test) end)
    packet = next_packet(socket)
    assert packet.command == 6
    answer(socket, packet, <<0::32, 7::32-little>>)
    assert {:ok, ref} = Task.await(task)

    data = Command.encode_notification([{DateTime.utc_now(), [{7, <<42::32-little>>}]}])
    answer(socket, packet, data, command: 8, invoke_id: 0)
    assert_receive {Client, ^ref, {:value, {0x4020, 0}, 42, %DateTime{}}}
  end

  test "the upload info is asked for with 64 bytes, as Beckhoff's servers want, else with 24" do
    {listen, port} = listen()
    client = scripted(port)
    socket = accept(listen)
    task = Task.async(fn -> Client.symbols(client) end)
    packet = next_packet(socket)
    assert packet.data == <<0xF00F::32-little, 0::32, 64::32-little>>
    answer(socket, packet, <<0x705::32-little, 0::32>>)
    packet = next_packet(socket)
    assert packet.data == <<0xF00F::32-little, 0::32, 24::32-little>>
    upload = FakePLC.symbol_upload()
    info = <<15::32-little, byte_size(upload)::32-little, 0::128>>
    answer(socket, packet, <<0::32, 24::32-little, info::binary>>)
    packet = next_packet(socket)
    assert packet.data == <<0xF00B::32-little, 0::32, byte_size(upload)::32-little>>
    answer(socket, packet, <<0::32, byte_size(upload)::32-little, upload::binary>>)
    assert {:ok, symbols} = Task.await(task)
    assert length(symbols) == 15
  end

  test "a router that closes the connection, as TwinCAT does without a route, is tried again" do
    {listen, port} = listen()
    client = scripted(port, backoff: {10, 20})
    socket = accept(listen)
    :gen_tcp.close(socket)
    # The reason depends on when the close lands: :closed, or a reset or einval from the socket.
    _again = accept(listen)
    eventually(fn -> Client.status(client) == :connected end)
  end
end
