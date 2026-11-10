defmodule Mix.Tasks.Ads.ReadTest do
  # Mix's shell is the whole VM's, so not async.
  use ExUnit.Case, async: false

  alias ADS.Test.{FakeDiscovery, FakePLC}
  alias Mix.Tasks.Ads.Read

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    plc = start_supervised!({FakePLC, system: true})
    udp = start_supervised!({FakeDiscovery, plc: plc})
    ports = ~w(--udp-port #{FakeDiscovery.port(udp)} --tcp-port #{FakePLC.port(plc)})
    %{plc: plc, udp: udp, ports: ports}
  end

  defp run(args) do
    Read.run(args)
    said()
  end

  defp said do
    receive do
      {:mix_shell, kind, [text]} -> [{kind, IO.chardata_to_string(text)} | said()]
    after
      0 -> []
    end
  end

  defp lines(args) do
    assert [{:info, "CX-FAKE (127.0.0.1), 5.36.69.176.1.1, AMS port 851\n"}, {:info, text}] =
             run(args)

    String.split(text, "\n", trim: true)
  end

  @pump %{"nSpeed" => 1450, "fTemp" => 61.5, "bRunning" => true, "eMode" => "eAuto", "sTag" => ""}

  test "a value on its line, and a structure member by member, in the PLC's order", c do
    :ok = FakePLC.put(c.plc, "MAIN.nCounter", 42)
    :ok = FakePLC.put(c.plc, "MAIN.stPump", %{@pump | "sTag" => "P-101"})
    :ok = FakePLC.put(c.plc, "MAIN.aValues", [1, 2, 3, 4, 5])

    assert lines(~w(127.0.0.1 MAIN.nCounter MAIN.stPump MAIN.aValues MAIN.eMode) ++ c.ports) == [
             "  MAIN.nCounter  DINT                 42",
             "  MAIN.stPump    ST_Pump",
             "    nSpeed    1450",
             "    fTemp     61.5",
             "    bRunning  true",
             "    eMode     eAuto",
             ~s(    sTag      "P-101"),
             "  MAIN.aValues   ARRAY [1..5] OF INT  [1, 2, 3, 4, 5]",
             "  MAIN.eMode     E_Mode               eOff"
           ]
  end

  test "an array element by element, the same ones next to each other once, and bits", c do
    assert lines(~w(127.0.0.1 MAIN.aPumps) ++ c.ports) == [
             "  MAIN.aPumps  ARRAY [0..1] OF ST_Pump",
             "    [0..1]",
             "      nSpeed    0",
             "      fTemp     0.0",
             "      bRunning  false",
             "      eMode     eOff",
             ~s(      sTag      "")
           ]

    :ok = FakePLC.put(c.plc, "MAIN.aPumps", [@pump, %{@pump | "nSpeed" => 0}])

    assert ["  MAIN.aPumps" <> _, "    [0]", "      nSpeed    1450" | rest] =
             lines(~w(127.0.0.1 MAIN.aPumps) ++ c.ports)

    assert "    [1]" in rest
    assert "      nSpeed    0" in rest

    assert lines(~w(127.0.0.1 MAIN.stFlags) ++ c.ports) == [
             "  MAIN.stFlags  ST_Flags",
             "    bA     false",
             "    bB     false",
             "    nRest  0"
           ]
  end

  test "a variable the PLC hasn't says so, and the others are read", c do
    assert lines(~w(127.0.0.1 MAIN.nNone MAIN.bOn) ++ c.ports) == [
             "  MAIN.nNone  not read: :device_symbol_not_found",
             "  MAIN.bOn    BOOL  false"
           ]
  end

  test "a PLC without a route, and wrong arguments, say so", c do
    plc = start_supervised!({FakePLC, system: true, routes: []}, id: :closed)
    ports = ~w(--udp-port #{FakeDiscovery.port(c.udp)} --tcp-port #{FakePLC.port(plc)})

    assert_raise Mix.Error,
                 ~r/No answer from CX-FAKE \(127.0.0.1\) over ADS \(:closed\).*mix ads.route/,
                 fn -> run(~w(127.0.0.1 MAIN.bOn) ++ ports) end

    assert_raise Mix.Error, ~r/Expected a PLC and the variables to read/, fn ->
      run(~w(127.0.0.1) ++ c.ports)
    end

    assert_raise Mix.Error, ~r/Unknown option --filter/, fn -> run(~w(--filter x)) end
  end
end
