defmodule ADS.BeckhoffTest do
  # The client against Beckhoff's own ADS libraries for .NET, version 7.0.389 (MIT License), and
  # Beckhoff's client against the fake PLC, run in Docker by test/beckhoff/peer, as
  # test/beckhoff/README.md says, and only when asked:
  #
  #     mix test --only beckhoff
  #
  # The libraries are used as a device on the network is, by what they send, through their
  # documented API; nothing of them is read or included.
  #
  # Where they differ from a PLC, the tests go around it:
  #
  #   * Beckhoff's router lets a connection from an address it has no route for be, and answers
  #     nothing on it, where TwinCAT closes it
  #   * its symbolic server lays out a structure's members one after another, with no gaps, where
  #     TwinCAT 3 aligns each to its size, up to 8
  #   * a STRING in UTF-8 has no TcEncoding attribute; so it's read with its type given
  #   * its system service, on port 10000, answers nothing to a device info
  #   * Beckhoff's client asks for a notification with 24 bytes, without the 16 reserved ones,
  #     which the fake takes
  use ExUnit.Case, async: false

  alias ADS.{Client, Discovery}
  alias ADS.Test.FakePLC

  @moduletag :beckhoff
  @moduletag timeout: 600_000

  @image "mcr.microsoft.com/dotnet/sdk:8.0.425"
  @peer Path.expand("peer", __DIR__)

  # The router's NetId, and the client's, as its route has it.
  @net_id "10.99.0.1.1.1"
  @local_net_id "10.99.0.2.1.1"

  # The variables of the peer's symbolic server, as it starts.
  @values %{
    "MAIN.nCounter" => -5,
    "MAIN.nSpeed" => 1500,
    "MAIN.bOn" => true,
    "MAIN.fTemp" => 21.5,
    "MAIN.fReal" => 1.5,
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
    "MAIN.tLong" => 1_500_000_000,
    "MAIN.dDate" => ~D[2026-10-28],
    "MAIN.dtStamp" => ~N[2026-10-28 12:00:00],
    "MAIN.todTime" => ~T[12:34:56.789],
    "MAIN.sText" =>
      "a text longer than eighty characters, which T_MaxString holds, being a STRING(255) by another name",
    "MAIN.nSint" => -100,
    "MAIN.nUsint" => 200,
    "MAIN.nByte" => 0xAB,
    "MAIN.nUint" => 60_000,
    "MAIN.nWord" => 0xABCD,
    "MAIN.nUdint" => 4_000_000_000,
    "MAIN.nDword" => 0xDEADBEEF,
    "MAIN.nLint" => -9_000_000_000_000_000_000,
    "MAIN.nUlint" => 18_000_000_000_000_000_000,
    "MAIN.nLword" => 0x0123456789ABCDEF,
    "MAIN.aMatrix" => [[1, 2], [3, 4], [5, 6]]
  }

  @types %{
    "MAIN.nCounter" => {"DINT", 4},
    "MAIN.nSpeed" => {"INT", 2},
    "MAIN.bOn" => {"BOOL", 1},
    "MAIN.fTemp" => {"LREAL", 8},
    "MAIN.fReal" => {"REAL", 4},
    "MAIN.sName" => {"STRING(20)", 21},
    "MAIN.wsText" => {"WSTRING(10)", 22},
    "MAIN.aValues" => {"ARRAY [1..5] OF INT", 10},
    "MAIN.stPump" => {"ST_Pump", 24},
    "MAIN.aPumps" => {"ARRAY [0..1] OF ST_Pump", 48},
    "MAIN.eMode" => {"E_Mode", 2},
    "MAIN.tDelay" => {"TIME", 4},
    "MAIN.tLong" => {"LTIME", 8},
    "MAIN.dDate" => {"DATE", 4},
    "MAIN.dtStamp" => {"DATE_AND_TIME", 4},
    "MAIN.todTime" => {"TIME_OF_DAY", 4},
    "MAIN.sText" => {"T_MaxString", 256},
    "MAIN.nSint" => {"SINT", 1},
    "MAIN.nUsint" => {"USINT", 1},
    "MAIN.nByte" => {"BYTE", 1},
    "MAIN.nUint" => {"UINT", 2},
    "MAIN.nWord" => {"WORD", 2},
    "MAIN.nUdint" => {"UDINT", 4},
    "MAIN.nDword" => {"DWORD", 4},
    "MAIN.nLint" => {"LINT", 8},
    "MAIN.nUlint" => {"ULINT", 8},
    "MAIN.nLword" => {"LWORD", 8},
    "MAIN.aMatrix" => {"ARRAY [0..2][1..2] OF DINT", 24},
    "GVL.sUtf8" => {"STRING(20)", 21}
  }

  # BECKHOFF_LOG=1 has the peer log all Beckhoff's libraries do to standard error.
  defp log, do: if(System.get_env("BECKHOFF_LOG") == "1", do: ~w(-e PEER_LOG=1), else: [])

  # The peer, built once, in a volume of its own, with the NuGet packages in another.
  setup_all do
    docker = System.find_executable("docker") || raise "docker must be installed for these tests"

    {output, status} =
      System.cmd(
        docker,
        ~w(run --rm -v yaads-beckhoff-nuget:/root/.nuget/packages -v yaads-beckhoff-build:/build
           -e PEER_BUILD=/build -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 -v) ++
          ["#{@peer}:/src:ro"] ++
          ~w(-w /src #{@image} dotnet build -c Release -o /build/out -nologo -v q),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("the peer didn't build:\n#{output}")
    %{docker: docker}
  end

  # A server of its own for each test, with a route for the client unless routed: false.
  setup %{docker: docker} = context do
    name = "yaads-beckhoff-#{System.unique_integer([:positive])}"
    route = if Map.get(context, :routed, true), do: [@local_net_id], else: []

    server =
      Port.open({:spawn_executable, docker}, [
        :binary,
        :exit_status,
        {:line, 1024},
        args:
          ~w(run --rm -i --name #{name} -p 127.0.0.1::48898 -p 127.0.0.1::48899/udp) ++
            log() ++
            ~w(-v yaads-beckhoff-build:/build:ro #{@image} dotnet /build/out/Peer.dll server) ++
            route
      ])

    gateway =
      receive do
        {^server, {:data, {:eol, "ready " <> gateway}}} -> gateway
        {^server, {:exit_status, status}} -> raise "the peer exited with #{status}"
      after
        60_000 -> raise "the peer didn't start"
      end

    on_exit(fn ->
      if Port.info(server), do: Port.close(server)
      System.cmd(docker, ["rm", "-f", name], stderr_to_stdout: true)
    end)

    port = fn spec ->
      {out, 0} = System.cmd(docker, ["port", name, spec])
      [_, port] = Regex.run(~r/:(\d+)$/m, out)
      String.to_integer(port)
    end

    tcp = port.("48898/tcp")

    client =
      start_supervised!(
        {Client,
         host: "127.0.0.1",
         port: tcp,
         net_id: @net_id,
         local_net_id: @local_net_id,
         timeout: 1000,
         backoff: {50, 200}}
      )

    %{client: client, tcp: tcp, udp: port.("48899/udp"), gateway: gateway}
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else: Process.sleep(50) && eventually(fun, tries - 1)
  end

  test "the device's name, version and state, and stopping and starting it", %{client: client} do
    assert Client.read_device_info(client) ==
             {:ok, %{name: "yaads-beckhoff", version: {3, 1, 4026}}}

    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
    assert Client.write_control(client, :stop) == :ok
    assert {:ok, %{ads_state: :stop}} = Client.read_state(client)
    assert Client.write_control(client, :run) == :ok
    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
  end

  test "every variable, by name, as Beckhoff's server describes and encodes it", %{
    client: client
  } do
    for {name, value} <- @values, do: assert(Client.read(client, name) == {:ok, value}, name)
    assert Client.read(client, "GVL.sUtf8", type: {:string, 20, :utf8}) == {:ok, "€uro, ½"}
  end

  test "members and elements, by name", %{client: client} do
    assert Client.read(client, "MAIN.stPump.fTemp") == {:ok, -1.5}
    assert Client.read(client, "MAIN.aPumps[1].sTag") == {:ok, "B"}
    assert Client.read(client, "MAIN.aValues[2]") == {:ok, 2}
    assert Client.write(client, "MAIN.aPumps[0].eMode", "eManual") == :ok
    assert {:ok, [%{"eMode" => "eManual"}, _]} = Client.read(client, "MAIN.aPumps")
  end

  test "written and read back", %{client: client} do
    for {name, value} <- [
          {"MAIN.nSpeed", -1234},
          {"MAIN.fTemp", -0.25},
          {"MAIN.sName", "Tank 2"},
          {"MAIN.wsText", "Ωmega"},
          {"MAIN.aValues", [5, 4, 3, 2, 1]},
          {"MAIN.stPump",
           %{
             "nSpeed" => 9,
             "fTemp" => 3.25,
             "bRunning" => false,
             "eMode" => "eOff",
             "sTag" => "X"
           }},
          {"MAIN.eMode", "eAuto"},
          {"MAIN.dtStamp", ~N[2027-01-02 03:04:05]},
          {"MAIN.nUlint", 1}
        ] do
      assert Client.write(client, name, value) == :ok, name
      assert Client.read(client, name) == {:ok, value}, name
    end
  end

  test "many at once, in Beckhoff's sum commands, each with its own result", %{client: client} do
    assert Client.read_many(client, ["MAIN.nSpeed", "MAIN.bOn", "MAIN.nNone", "MAIN.stPump"]) ==
             {:ok,
              [
                {:ok, 1500},
                {:ok, true},
                {:error, :device_symbol_not_found},
                {:ok, @values["MAIN.stPump"]}
              ]}

    assert Client.write_many(client, [{"MAIN.nSpeed", 5}, {"MAIN.bOn", false}]) ==
             {:ok, [:ok, :ok]}

    assert Client.read_many(client, ["MAIN.nSpeed", "MAIN.bOn"]) ==
             {:ok, [{:ok, 5}, {:ok, false}]}
  end

  test "the descriptions of all its variables and types", %{client: client} do
    assert {:ok, symbols} = Client.symbols(client)

    assert Map.new(symbols, &{&1.name, {&1.type, &1.size}}) == @types

    assert {:ok, types} = Client.data_types(client)
    names = MapSet.new(types, & &1.name)

    for name <- ~w[INT LREAL STRING(20) WSTRING(10) E_Mode ST_Pump T_MaxString],
        do: assert(name in names, name)

    assert %{members: members} = Enum.find(types, &(&1.name == "ST_Pump"))

    assert for(m <- members, do: {m.name, m.offset}) ==
             [{"nSpeed", 0}, {"fTemp", 2}, {"bRunning", 10}, {"eMode", 11}, {"sTag", 13}]
  end

  test "notifications on change, and cyclic, until unsubscribed", %{client: client} do
    assert {:ok, ref} = Client.subscribe(client, ["MAIN.nCounter", "MAIN.stPump"])
    assert_receive {Client, ^ref, {:value, "MAIN.nCounter", -5, %DateTime{}}}, 2000
    assert_receive {Client, ^ref, {:value, "MAIN.stPump", %{"nSpeed" => 7}, _}}, 2000
    assert Client.write(client, "MAIN.nCounter", 42) == :ok
    assert_receive {Client, ^ref, {:value, "MAIN.nCounter", 42, _}}, 2000
    assert Client.unsubscribe(client, ref) == :ok

    assert {:ok, ref} = Client.subscribe(client, "MAIN.fTemp", mode: :cyclic, cycle_time: 50)

    for _ <- 1..3,
        do: assert_receive({Client, ^ref, {:value, "MAIN.fTemp", 21.5, _}}, 2000)

    assert Client.unsubscribe(client, ref) == :ok
  end

  test "the errors of the device, and of the router, for names and ports they haven't", %{
    client: client
  } do
    assert Client.read(client, "MAIN.nNone") == {:error, :device_symbol_not_found}
    assert Client.read_state(client, port: 852) == {:error, :target_port_not_found}
    assert {:ok, %{ads_state: _}} = Client.read_state(client, port: 10000)
  end

  @tag routed: false
  test "over UDP: the router's NetId, a route added with the password that lets a client in, deleted",
       %{client: client, udp: udp, gateway: gateway} do
    assert {:ok, %{net_id: @net_id, name: name}} = Discovery.info({127, 0, 0, 1}, port: udp)
    assert is_binary(name)

    # Without a route, nothing comes; two timeouts, and the client tries again.
    assert Client.read_state(client) == {:error, :timeout}
    assert Client.read_state(client) == {:error, :timeout}

    route = [port: udp, net_id: @local_net_id, address: gateway, name: "yaads"]

    assert Discovery.add_route({127, 0, 0, 1}, [password: "wrong"] ++ route) ==
             {:error, :device_invalid_access}

    assert Discovery.add_route({127, 0, 0, 1}, [password: "1"] ++ route) == :ok
    eventually(fn -> match?({:ok, %{ads_state: :run}}, Client.read_state(client)) end)

    # Deleted as Apache PLC4X describes it, with the login; once, and then there's none to delete.
    # The connection that's open stays, with Beckhoff's router.
    assert Discovery.delete_route({127, 0, 0, 1}, [password: "wrong"] ++ route) ==
             {:error, :device_invalid_access}

    assert Discovery.delete_route({127, 0, 0, 1}, [password: "1"] ++ route) == :ok

    assert Discovery.delete_route({127, 0, 0, 1}, [password: "1"] ++ route) ==
             {:error, :device_not_found}

    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
    assert Discovery.add_route({127, 0, 0, 1}, [password: "1"] ++ route) == :ok
  end

  test "Beckhoff's client makes out the fake's descriptions and values as the fake means them",
       %{docker: docker} do
    # On the host's network, as a router reaches a PLC at the port it listens on itself.
    [port, loopback] = for _ <- 1..2, do: free_port()
    plc = start_supervised!({FakePLC, port: port, ip: {127, 0, 0, 1}})

    values = %{
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
      "MAIN.sText" => "a text for T_MaxString",
      "MAIN.stFlags" => %{"bA" => false, "bB" => true, "nRest" => 7},
      "GVL.sUtf8" => "€uro, ½"
    }

    for {name, value} <- values, do: :ok = FakePLC.put(plc, name, value)

    {output, status} =
      System.cmd(
        docker,
        ~w(run --rm --network host) ++
          log() ++
          ~w(-v yaads-beckhoff-build:/build:ro #{@image}
           dotnet /build/out/Peer.dll client #{ADS.NetId.to_string(FakePLC.net_id())} #{port} #{loopback})
      )

    assert status == 0
    {:ok, tokens, _} = output |> String.to_charlist() |> :erl_scan.string()

    {:ok, %{"symbols" => symbols, "types" => types, "writes" => writes}} =
      :erl_parse.parse_term(tokens)

    assert for(s <- symbols, do: {s["name"], s["type"], s["size"]}) ==
             for(
               {name, type_name, type, _, _} <- FakePLC.variables(),
               do: {name, type_name, ADS.Type.size(type)}
             )

    for %{"name" => name, "value" => value} <- symbols,
        do: assert(beckhoff(value) == values[name], name)

    type_names = for t <- types, do: t["name"]

    for {name, _entry} <- FakePLC.type_entries(), do: assert(name in type_names, name)

    assert Enum.all?(writes, &(&1["result"] == "ok")), inspect(writes)
    assert FakePLC.get(plc, "MAIN.nSpeed") == 1234
    assert FakePLC.get(plc, "MAIN.fTemp") == -0.25
    assert FakePLC.get(plc, "MAIN.sName") == "Beckhoff"
    assert FakePLC.get(plc, "MAIN.wsText") == "Ωmega"
    assert FakePLC.get(plc, "MAIN.aValues") == [1, 2, 33, 4, 5]
    assert %{"fTemp" => 99.5} = FakePLC.get(plc, "MAIN.stPump")
    assert [_, %{"nSpeed" => -2}] = FakePLC.get(plc, "MAIN.aPumps")
  end

  # A value as the peer gives it, as the fake has it.
  defp beckhoff(%{"ms" => ms}), do: ms
  defp beckhoff(%{"dt" => dt}), do: NaiveDateTime.from_iso8601!(dt)
  defp beckhoff(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, beckhoff(v)} end)
  defp beckhoff(list) when is_list(list), do: Enum.map(list, &beckhoff/1)
  defp beckhoff(value), do: value

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
