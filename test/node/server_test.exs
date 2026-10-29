defmodule ADS.NodeServerTest do
  # The client against another's idea of an ADS device: jisotalo's ads-server, run by
  # test/node/server.js, and only when asked, as test/node/README.md says. Its packets, and its
  # notifications above all, are built by ads-server, not by anything of yaads's.
  #
  # ads-server is used as a device on the network is, by what it sends; nothing of it is read or
  # included. Where it differs from a PLC, as ads-server 1.1.2 does, the tests go around it:
  #
  #   * it addresses a notification to its own NetId rather than the client's; server.js sends
  #     them to the client's
  #   * it flags a notification as a response (state flags 0x0005); the client takes it as a
  #     notification all the same, and the last test reads them off a socket of its own as well
  use ExUnit.Case, async: false

  alias ADS.{AMS, Client, Command}

  @moduletag :node

  @net_id "10.11.12.13.1.1"

  # A server of its own for each test, and a client of it.
  setup do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    server = node!("server.js", [Integer.to_string(port)])

    receive do
      {^server, {:data, {:eol, "ready"}}} -> :ok
      {^server, {:exit_status, status}} -> raise "ads-server exited with #{status}"
    after
      10_000 -> raise "ads-server didn't start"
    end

    client = start_supervised!({Client, host: "127.0.0.1", port: port, net_id: @net_id})
    %{port: port, client: client}
  end

  defp node!(script, args) do
    node = System.get_env("NODE", "node")
    executable = System.find_executable(node) || raise "#{node} not found; NODE gives another"

    if not File.dir?(Path.expand("node_modules", __DIR__)),
      do: raise("the Node tests need `npm ci` in test/node first")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 1024},
        cd: __DIR__,
        args: [script | args]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end

  test "the device's name, version and state, and write control setting it", %{client: client} do
    assert Client.read_device_info(client) == {:ok, %{name: "ads-server", version: {1, 2, 3}}}
    assert Client.read_state(client) == {:ok, %{ads_state: :run, device_state: 7}}
    assert Client.write_control(client, :stop, device_state: 3) == :ok
    assert Client.read_state(client) == {:ok, %{ads_state: :stop, device_state: 3}}
  end

  test "by index group and offset: written, read back, and read-written", %{client: client} do
    assert Client.write(client, {0x4020, 4}, -1234, type: :dint) == :ok
    assert Client.read(client, {0x4020, 4}, type: :dint) == {:ok, -1234}
    assert Client.write(client, {0x4020, 8}, [1, 2, 3], type: {:array, :int, [{1, 3}]}) == :ok
    assert Client.read(client, {0x4020, 8}, type: {:array, :int, [{1, 3}]}) == {:ok, [1, 2, 3]}
    assert Client.request(client, {:read_write, 0x4021, 0, 3, <<1, 2, 3>>}) == {:ok, <<3, 2, 1>>}
  end

  test "the errors of a device, for groups, offsets and ports it hasn't", %{client: client} do
    assert Client.read(client, {0x9999, 0}, type: :int) == {:error, :device_invalid_group}
    assert Client.read(client, {0x4020, 63}, type: :int) == {:error, :device_invalid_offset}
    assert Client.read_state(client, port: 852) == {:error, :target_port_not_found}
  end

  test "many at once, from a device without sum commands: one at a time", %{client: client} do
    assert Client.write_many(client, [{{0x4020, 0}, 9, :int}, {{0x4020, 2}, true, :bool}]) ==
             {:ok, [:ok, :ok]}

    assert Client.read_many(client, [{{0x4020, 0}, :int}, {{0x4020, 2}, :bool}]) ==
             {:ok, [{:ok, 9}, {:ok, true}]}
  end

  test "notifications, added and deleted by the client, and their values", %{client: client} do
    assert {:ok, ref} = Client.subscribe(client, {{0x4020, 4}, :dint})
    assert_receive {Client, ^ref, {:value, {0x4020, 4}, 0, %DateTime{}}}, 2000
    assert :ok = Client.write(client, {0x4020, 4}, 42, type: :dint)
    assert_receive {Client, ^ref, {:value, {0x4020, 4}, 42, %DateTime{}}}, 2000
    assert {:ok, cyclic} = Client.subscribe(client, {{0x4020, 0}, :int}, mode: :cyclic)
    assert Client.unsubscribe(client, ref) == :ok
    assert Client.unsubscribe(client, cyclic) == :ok
    assert {:ok, _} = Client.read_state(client)
  end

  test "notifications as ads-server sends them: the value at once, then each change", %{
    port: port
  } do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    add = {:add_notification, 0x4020, 4, 4, :on_change, 0, 0}
    send_request(socket, 1, add)
    assert %AMS{command: 6, invoke_id: 1} = answer = next(socket)
    assert {:ok, handle} = Command.decode_response(add, answer.data)

    assert {:ok, [{%DateTime{} = time, [{^handle, <<0::32>>}]}]} = notification(socket)
    assert abs(DateTime.diff(time, DateTime.utc_now(), :second)) < 5

    send_request(socket, 2, {:write, 0x4020, 4, <<42::32-little>>})
    assert %AMS{command: 3, invoke_id: 2, data: <<0::32>>} = next(socket)
    assert {:ok, [{_time, [{^handle, <<42::32-little>>}]}]} = notification(socket)
  end

  defp send_request(socket, invoke_id, request) do
    {command, data} = Command.encode_request(request)

    packet = %AMS{
      target: ADS.NetId.parse!(@net_id),
      target_port: 851,
      source: <<127, 0, 0, 1, 1, 1>>,
      source_port: 33_000,
      command: command,
      invoke_id: invoke_id,
      data: data
    }

    :ok = :gen_tcp.send(socket, AMS.encode(packet))
  end

  defp notification(socket) do
    assert %AMS{command: 8, state_flags: 0x0005, target_port: 33_000} = packet = next(socket)
    Command.decode_notification(packet.data)
  end

  # The next packet, and what comes after it is kept for the next.
  defp next(socket) do
    buffer = Process.get(socket, <<>>)

    case AMS.decode(buffer, :tcp) do
      {:ok, packet, rest} ->
        Process.put(socket, rest)
        packet

      :more ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
        Process.put(socket, buffer <> data)
        next(socket)
    end
  end
end
