defmodule ADS.NodeClientTest do
  # The fake PLC against another's client: jisotalo's ads-client, run by test/node/client.js, and
  # only when asked, as test/node/README.md says. It reads every variable by the fake's own
  # descriptions of them, decoded its own way, as it does a PLC's; so a misreading of the format
  # that the fake and the client share shows here.
  #
  # ads-client is used as a client on the network is, by what it sends; nothing of it is read or
  # included. Where it differs from a PLC's clients, as ads-client 2.2.0 does, the tests go
  # around it:
  #
  #   * it reads a BIT member of a structure as the whole byte at the member's offset, as if in
  #     bytes, though the member is flagged as counting bits (0x20); so ST_Flags is read for its
  #     BYTE alone
  use ExUnit.Case, async: false

  alias ADS.Test.FakePLC

  @moduletag :node

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
    "MAIN.sText" => "a text of a T_MaxString",
    "MAIN.stFlags" => %{"bA" => false, "bB" => true, "nRest" => 7},
    "GVL.sUtf8" => "€uro, ½"
  }

  # A fake PLC with TwinCAT's system service, which ads-client asks for, and ads-client connected
  # to it, with what it read first.
  setup do
    plc = start_supervised!({FakePLC, system: true})
    for {name, value} <- @values, do: :ok = FakePLC.put(plc, name, value)
    node = node!("client.js", [Integer.to_string(FakePLC.port(plc))])
    %{plc: plc, node: node, first: line!(node)}
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
        {:line, 1_000_000},
        cd: __DIR__,
        args: [script | args]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end

  # A line of JSON, decoded by OTP 27's :json, called at run time as OTP 26 has none.
  defp line!(node) do
    receive do
      {^node, {:data, {:eol, line}}} -> apply(:json, :decode, [line])
      {^node, {:exit_status, status}} -> raise "ads-client exited with #{status}"
    after
      10_000 -> raise "nothing from ads-client"
    end
  end

  defp step!(node), do: Port.command(node, "\n")

  # A value of a type of the fake's, as ads-client gives it: an enumeration as its name and
  # number, a DATE_AND_TIME as a time in UTC.
  defp js({:enum, _base, values}, name),
    do: %{"name" => name, "value" => values |> Map.new() |> Map.fetch!(name)}

  defp js({:struct, _size, members}, map),
    do: Map.new(members, fn {n, _, t} -> {n, js(t, map[n])} end)

  defp js({:array, type, _dims}, list), do: Enum.map(list, &js(type, &1))

  defp js(:date_and_time, time), do: NaiveDateTime.to_iso8601(time) <> ".000Z"

  defp js(_type, value), do: value

  test "ads-client uploads the fake's symbols and data types, and reads every variable by them",
       %{first: first} do
    assert first["symbols"] == Enum.map(FakePLC.variables(), &elem(&1, 0))
    assert first["types"] == Enum.map(FakePLC.type_entries(), &elem(&1, 0))

    for {name, _type_name, type, _id, _attributes} <- FakePLC.variables(),
        name != "MAIN.stFlags" do
      assert first["values"][name] == js(type, @values[name]), name
    end

    assert first["values"]["MAIN.stFlags"]["nRest"] == 7
  end

  test "ads-client writes by name, by the fake's descriptions", %{plc: plc, node: node} do
    step!(node)
    assert line!(node) == "written"
    assert FakePLC.get(plc, "MAIN.nSpeed") == -1234
    assert FakePLC.get(plc, "MAIN.sName") == "Tank 2"
    assert FakePLC.get(plc, "MAIN.aValues") == [5, 4, 3, 2, 1]
    assert FakePLC.get(plc, "MAIN.eMode") == "eAuto"
    assert FakePLC.get(plc, "GVL.sUtf8") == "½ € ¾"

    assert FakePLC.get(plc, "MAIN.stPump") ==
             %{
               "nSpeed" => 9,
               "fTemp" => 0.25,
               "bRunning" => false,
               "eMode" => "eManual",
               "sTag" => "T9"
             }
  end

  test "the fake's notifications, as ads-client takes them: the value at once, then each change",
       %{plc: plc, node: node} do
    step!(node)
    assert line!(node) == "written"
    step!(node)
    assert Enum.sort([line!(node), line!(node)]) == Enum.sort(["subscribed", %{"value" => -5}])
    :ok = FakePLC.put(plc, "MAIN.nCounter", 42)
    assert line!(node) == %{"value" => 42}
  end
end
