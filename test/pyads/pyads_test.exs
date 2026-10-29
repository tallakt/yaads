defmodule ADS.PyadsTest do
  # The client against another's idea of an ADS device: pyads's test server, run by
  # test/pyads/server.py, and only when asked:
  #
  #     python3 -m venv ~/.venvs/pyads && ~/.venvs/pyads/bin/pip install pyads
  #     PYADS_PYTHON=~/.venvs/pyads/bin/python mix test --only pyads
  #
  # The server is used as a device on the network is, by what it sends; nothing of pyads is read
  # or included.
  #
  # Where it differs from a PLC, as pyads 3.6.0 does, the tests go around it:
  #
  #   * it ends the name and type of a symbol's description with a space rather than a zero, and
  #     leaves out the zero after the comment, which the client takes as a description that
  #     doesn't add up; so names are read with their types given
  #   * its device info has a name of 11 bytes rather than 16, which the client takes as an
  #     invalid response
  #   * it doesn't answer a request for a name it doesn't have, sum commands of handles
  #     (0xF082) or of values by handle, or the release of a handle, and answers nothing more on
  #     that connection; so sum commands go by index group and offset
  #   * it takes notifications, and lets them go, but never sends one
  use ExUnit.Case, async: false

  alias ADS.Client

  @moduletag :pyads

  @types %{
    "MAIN.nSpeed" => :int,
    "MAIN.nCounter" => :dint,
    "MAIN.nUdint" => :udint,
    "MAIN.bOn" => :bool,
    "MAIN.fTemp" => :lreal,
    "MAIN.fReal" => :real,
    "MAIN.sName" => {:string, 80},
    "MAIN.aValues" => {:array, :int, [{1, 5}]}
  }

  # A server of its own for each test, with the variables as they start.
  setup do
    python =
      System.get_env("PYADS_PYTHON") || raise "PYADS_PYTHON must be set for the pyads tests"

    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    server =
      Port.open({:spawn_executable, Path.expand(python)}, [
        :binary,
        :exit_status,
        {:line, 1024},
        args: ["-I", Path.expand("server.py", __DIR__), Integer.to_string(port)]
      ])

    receive do
      {^server, {:data, {:eol, "ready"}}} -> :ok
      {^server, {:exit_status, status}} -> raise "pyads's test server exited with #{status}"
    after
      10_000 -> raise "pyads's test server didn't start"
    end

    on_exit(fn -> if Port.info(server), do: Port.close(server) end)
    client = start_supervised!({Client, host: "127.0.0.1", port: port, net_id: "127.0.0.1.1.1"})
    %{port: port, client: client}
  end

  defp read(client, name), do: Client.read(client, name, type: @types[name])
  defp write(client, name, value), do: Client.write(client, name, value, type: @types[name])

  test "the variables, by handles from their names", %{client: client} do
    assert read(client, "MAIN.nSpeed") == {:ok, 1500}
    assert read(client, "MAIN.nCounter") == {:ok, -5}
    assert read(client, "MAIN.nUdint") == {:ok, 4_000_000_000}
    assert read(client, "MAIN.bOn") == {:ok, true}
    assert read(client, "MAIN.fTemp") == {:ok, 21.5}
    assert read(client, "MAIN.fReal") == {:ok, 1.5}
    assert read(client, "MAIN.sName") == {:ok, "Pump 1"}
    assert read(client, "MAIN.aValues") == {:ok, [1, 2, 3, 4, 5]}
  end

  test "written and read back", %{client: client} do
    for {name, value} <- [
          {"MAIN.nSpeed", -1234},
          {"MAIN.bOn", false},
          {"MAIN.fTemp", -0.25},
          {"MAIN.sName", "Tank 2"},
          {"MAIN.aValues", [5, 4, 3, 2, 1]}
        ] do
      assert write(client, name, value) == :ok, name
      assert read(client, name) == {:ok, value}, name
    end
  end

  test "by index group and offset", %{client: client} do
    assert Client.read(client, {0x4020, 8}, type: :int) == {:ok, 42}
    assert Client.write(client, {0x4020, 8}, -7, type: :int) == :ok
    assert Client.read(client, "GVL.nAddressed", type: :int) == {:ok, -7}
  end

  test "many at once, in sum commands, each with its own result, in order", %{client: client} do
    assert Client.write_many(client, [{{0x4020, 8}, 9, :int}, {{12345, 20001}, 42, :dint}]) ==
             {:ok, [:ok, :ok]}

    assert Client.read_many(client, [{{0x4020, 8}, :int}, {{12345, 20001}, :dint}]) ==
             {:ok, [{:ok, 9}, {:ok, 42}]}

    assert read(client, "MAIN.nCounter") == {:ok, 42}
  end

  test "the device's state", %{client: client} do
    assert {:ok, %{ads_state: _, device_state: _}} = Client.read_state(client)
  end

  test "notifications, added and deleted", %{client: client} do
    assert {:ok, ref} = Client.subscribe(client, {{0x4020, 8}, :int}, cycle_time: 10)
    assert Client.unsubscribe(client, ref) == :ok
  end

  test "a device that stops answering is connected to again", %{port: port} do
    client =
      start_supervised!(
        {Client, host: "127.0.0.1", port: port, net_id: "127.0.0.1.1.1", timeout: 300},
        id: :quick
      )

    assert Client.read(client, "MAIN.nNone", type: :int) == {:error, :timeout}
    assert Client.read(client, "MAIN.nSpeed", type: :int) == {:error, :timeout}

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(100)
             match?({:ok, _}, Client.read(client, "MAIN.nSpeed", type: :int))
           end)
  end
end
