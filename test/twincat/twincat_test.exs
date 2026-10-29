defmodule ADS.TwinCATTest do
  # Against a real PLC, running the program in test/twincat/plc, and only when asked:
  #
  #     TWINCAT_HOST=10.0.0.5 TWINCAT_NET_ID=5.36.69.176.1.1 mix test --only twincat
  #
  # Also, if set:
  #
  #   * TWINCAT_LOCAL_NET_ID - the client's NetId, as the PLC's route has it, if it isn't the
  #     client's address with .1.1
  #   * TWINCAT_PSK - "identity:password", to try Secure ADS with a pre-shared key too
  #   * TWINCAT_LONG - 1, for the 64-bit dates and times of GVL_Long, TwinCAT 3.1.4026 on
  #
  # The tests write the program's variables, and leave them as they wrote them; they don't stop
  # the PLC.
  use ExUnit.Case, async: false

  alias ADS.{Client, Type}

  @moduletag :twincat

  @mode {:enum, :int, [{"eOff", 0}, {"eAuto", 1}, {"eManual", 2}]}

  @pump Type.layout([
          {"nSpeed", :int},
          {"fTemp", :lreal},
          {"bRunning", :bool},
          {"eMode", @mode},
          {"sTag", {:string, 10}}
        ])

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
    "MAIN.sText" => String.duplicate("a text longer than eighty characters, ", 6),
    "MAIN.stFlags" => %{"bA" => false, "bB" => true, "nRest" => 7},
    "GVL.sUtf8" => "€uro, ½",
    "MAIN.nSint" => -128,
    "MAIN.nUsint" => 200,
    "MAIN.nUint" => 60_000,
    "MAIN.nUdint" => 4_000_000_000,
    "MAIN.nLint" => -9_000_000_000_000_000_000,
    "MAIN.nUlint" => 18_000_000_000_000_000_000,
    "MAIN.nByte" => 255,
    "MAIN.nWord" => 0xBEEF,
    "MAIN.nDword" => 0xDEADBEEF,
    "MAIN.nLword" => 0xFFFF_FFFF_FFFF_FFFF,
    "MAIN.fReal" => 1.5,
    "MAIN.tLong" => 1_500_000_007,
    "MAIN.dDate" => ~D[2026-10-28],
    "MAIN.todTime" => ~T[12:34:56.789],
    "MAIN.aMatrix" => [[1, 2, 3], [-4, -5, -6]],
    "MAIN.stPacked" => %{"nSmall" => -1, "fBig" => 2.5}
  }

  defp env!(name), do: System.get_env(name) || raise("#{name} must be set for the TwinCAT tests")

  defp connect(opts) do
    local =
      if net_id = System.get_env("TWINCAT_LOCAL_NET_ID"), do: [local_net_id: net_id], else: []

    client =
      start_supervised!({Client, [host: env!("TWINCAT_HOST"), timeout: 5000] ++ local ++ opts},
        id: make_ref()
      )

    connected? =
      Enum.reduce_while(1..100, false, fn _, _ ->
        if Client.status(client) == :connected,
          do: {:halt, true},
          else: Process.sleep(50) && {:cont, false}
      end)

    if not connected?,
      do:
        flunk(
          "no connection to the PLC: #{inspect(Client.status(client))}; is there a route for this client?"
        )

    client
  end

  setup do
    %{client: connect(net_id: env!("TWINCAT_NET_ID"))}
  end

  test "the device is a running PLC of TwinCAT 3", %{client: client} do
    assert {:ok, %{name: name, version: {3, 1, build}}} = Client.read_device_info(client)
    assert is_binary(name) and build >= 4020
    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
  end

  test "a variable of each type, written and read back by name, as the PLC describes it", %{
    client: client
  } do
    for {name, value} <- @values do
      assert Client.write(client, name, value) == :ok, name
      assert Client.read(client, name) == {:ok, value}, name
    end
  end

  test "the PLC lays out structures as ADS.Type.layout/2 does", %{client: client} do
    assert Client.type(client, "ST_Pump") == {:ok, @pump}

    assert Client.type(client, "ST_Packed") ==
             {:ok, Type.layout([{"nSmall", :sint}, {"fBig", :lreal}], pack_mode: 1)}

    assert Client.type(client, "ST_Flags") ==
             {:ok, {:struct, 2, [{"bA", 0, :bit}, {"bB", 1, :bit}, {"nRest", 1, :byte}]}}

    assert Client.type(client, "E_Mode") == {:ok, @mode}

    assert Client.type(client, "U_Value") ==
             {:ok,
              {:union, 4,
               [
                 {"nDint", 0, :dint},
                 {"fReal", 0, :real},
                 {"aBytes", 0, {:array, :byte, [{0, 3}]}}
               ]}}
  end

  test "a union reads as each of its members, and is written one at a time", %{client: client} do
    assert Client.write(client, "MAIN.uValue", %{"fReal" => 1.5}) == :ok

    assert Client.read(client, "MAIN.uValue") ==
             {:ok, %{"nDint" => 0x3FC00000, "fReal" => 1.5, "aBytes" => [0, 0, 0xC0, 0x3F]}}
  end

  test "a pointer is as big as the PLC's addresses", %{client: client} do
    assert {:ok, address} = Client.read(client, "MAIN.pnSpeed")
    assert is_integer(address) and address > 0
  end

  test "many at once, in sum commands, each with its own result, in order", %{client: client} do
    assert Client.write_many(client, [
             {"MAIN.nCounter", 42},
             {"MAIN.nNone", 1},
             {"MAIN.sName", "Tank"}
           ]) ==
             {:ok, [:ok, {:error, :device_symbol_not_found}, :ok]}

    assert Client.read_many(client, ["MAIN.nCounter", "MAIN.nNone", "MAIN.sName"]) ==
             {:ok, [{:ok, 42}, {:error, :device_symbol_not_found}, {:ok, "Tank"}]}

    # more than 500, in several
    names = for i <- 0..599, do: "MAIN.aBig[#{i}]"

    assert {:ok, results} =
             Client.write_many(
               client,
               for({name, i} <- Enum.with_index(names), do: {name, rem(i, 256)})
             )

    assert Enum.all?(results, &(&1 == :ok))
    assert Client.read_many(client, names) == {:ok, for(i <- 0..599, do: {:ok, rem(i, 256)})}
    assert {:ok, big} = Client.read(client, "MAIN.aBig")
    assert big == for(i <- 0..599, do: rem(i, 256))
  end

  test "the PLC's descriptions of its variables and types", %{client: client} do
    assert {:ok, symbols} = Client.symbols(client)
    assert %ADS.Symbol{type: "INT", size: 2} = Enum.find(symbols, &(&1.name == "MAIN.nSpeed"))
    assert {:ok, types} = Client.data_types(client)
    assert "ST_Pump" in Enum.map(types, & &1.name)

    assert {:ok, %ADS.Symbol{attributes: %{"TcEncoding" => "UTF-8"}}} =
             Client.symbol(client, "GVL.sUtf8")
  end

  test "the errors of a PLC and its router", %{client: client} do
    assert Client.read(client, "MAIN.nNone") == {:error, :device_symbol_not_found}
    assert Client.read_state(client, port: 859) == {:error, :target_port_not_found}
  end

  test "notifications on change: the value at once, then each change", %{client: client} do
    :ok = Client.write(client, "MAIN.nSpeed", 1000)
    assert {:ok, ref} = Client.subscribe(client, ["MAIN.nSpeed", "MAIN.stPump"], cycle_time: 10)
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 1000, %DateTime{}}}, 2000
    assert_receive {Client, ^ref, {:value, "MAIN.stPump", %{"nSpeed" => _}, %DateTime{}}}, 2000

    :ok = Client.write(client, "MAIN.nSpeed", 1234)
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 1234, _}}, 2000
    assert Client.unsubscribe(client, ref) == :ok
  end

  test "cyclic notifications, of a value that changes every cycle", %{client: client} do
    assert {:ok, ref} = Client.subscribe(client, "MAIN.nTicks", mode: :cyclic, cycle_time: 10)

    ticks =
      for _ <- 1..5 do
        assert_receive {Client, ^ref, {:value, "MAIN.nTicks", ticks, %DateTime{}}}, 2000
        ticks
      end

    assert ticks == Enum.sort(ticks) and length(Enum.uniq(ticks)) > 1
  end

  @tag skip:
         if(System.get_env("TWINCAT_LONG") != "1",
           do: "TWINCAT_LONG=1 for GVL_Long, TwinCAT 3.1.4026 on"
         )
  test "the 64-bit dates and times", %{client: client} do
    for {name, value} <- [
          {"GVL_Long.ldDate", ~D[2026-10-28]},
          {"GVL_Long.ldtStamp", ~N[2026-10-28 12:34:56.123456]},
          {"GVL_Long.ltodTime", ~T[23:59:59.999999]}
        ] do
      assert Client.write(client, name, value) == :ok, name
      assert Client.read(client, name) == {:ok, value}, name
    end
  end

  @tag skip:
         if(System.get_env("TWINCAT_PSK") == nil,
           do: "TWINCAT_PSK=identity:password for Secure ADS"
         )
  test "Secure ADS, with a pre-shared key" do
    [identity, password] = String.split(env!("TWINCAT_PSK"), ":", parts: 2)
    client = connect(secure: [psk: {identity, password}])
    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
    assert :ok = Client.write(client, "MAIN.nSpeed", 77)
    assert Client.read(client, "MAIN.nSpeed") == {:ok, 77}
  end
end
