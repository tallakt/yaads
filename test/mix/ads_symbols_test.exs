defmodule Mix.Tasks.Ads.SymbolsTest do
  # Mix's shell is the whole VM's, so not async.
  use ExUnit.Case, async: false

  alias ADS.Test.{FakeDiscovery, FakePLC}
  alias Mix.Tasks.Ads.Symbols

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    plc = start_supervised!({FakePLC, system: true})
    udp = start_supervised!({FakeDiscovery, plc: plc})
    %{udp: udp, ports: ~w(--udp-port #{FakeDiscovery.port(udp)} --tcp-port #{FakePLC.port(plc)})}
  end

  defp run(args) do
    Symbols.run(args)
    said()
  end

  defp said do
    receive do
      {:mix_shell, kind, [text]} -> [{kind, IO.chardata_to_string(text)} | said()]
    after
      0 -> []
    end
  end

  test "every variable by name, with its type, size and comment", c do
    assert [{:info, "CX-FAKE (127.0.0.1), 5.36.69.176.1.1, AMS port 851\n"}, {:info, text}] =
             run(["127.0.0.1"] ++ c.ports)

    assert ["  Name" <> header | rows] = String.split(text, "\n", trim: true)
    assert header =~ ~r/^\s+Type\s+Size\s+Comment$/
    assert List.last(rows) == "  15 variables"
    assert length(rows) == 16

    # In order of their names, in any case.
    assert hd(rows) =~ ~r/^  GVL\.sUtf8\s+STRING\(20\)\s+21\s+the GVL\.sUtf8$/
    assert Enum.at(rows, 1) =~ ~r/^  MAIN\.aPumps\s+ARRAY \[0\.\.1\] OF ST_Pump\s+\d+\s+the MAIN/
    assert Enum.any?(rows, &(&1 =~ ~r/^  MAIN\.bOn\s+BOOL\s+1\s+the MAIN\.bOn$/))
  end

  test "--filter keeps the names with any of the texts in them, in any case", c do
    assert [_, {:info, text}] = run(~w(127.0.0.1 --filter pump --filter TEMP) ++ c.ports)

    assert [_header | rows] = String.split(text, "\n", trim: true)
    names = for row <- Enum.drop(rows, -1), do: row |> String.split() |> hd()
    assert names == ["MAIN.aPumps", "MAIN.fTemp", "MAIN.stPump"]
    assert List.last(rows) == "  3 of 15 variables"

    assert [_, {:info, "  0 of 15 variables\n"}] = run(~w(127.0.0.1 --filter nothing) ++ c.ports)
  end

  test "--tsv gives them tab-separated under a header, and nothing else", c do
    assert [{:info, text}] = run(~w(127.0.0.1 --tsv --filter utf8 --filter bon) ++ c.ports)
    # The shell ends the last line, and no empty one comes after it.
    refute String.ends_with?(text, "\n")

    assert [header, utf8, on] =
             text |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))

    assert header == ~w(name type size index_group index_offset flags comment)
    assert ["MAIN.bOn", "BOOL", "1", "0x4040", _offset, "type_guid", "the MAIN.bOn"] = on

    assert ["GVL.sUtf8", "STRING(20)", "21", "0x4040", _, "type_guid,attributes", "the GVL.sUtf8"] =
             utf8
  end

  test "a PLC without a route, or without a runtime on the port, says so", c do
    assert_raise Mix.Error, ~r/AMS port 852 \(.+\)\. Is a PLC runtime there/, fn ->
      run(~w(127.0.0.1 --ams-port 852) ++ c.ports)
    end

    plc = start_supervised!({FakePLC, system: true, routes: []}, id: :closed)
    ports = ~w(--udp-port #{FakeDiscovery.port(c.udp)} --tcp-port #{FakePLC.port(plc)})

    assert_raise Mix.Error,
                 ~r/No answer from CX-FAKE \(127.0.0.1\) over ADS \(:closed\).*mix ads.route/,
                 fn -> run(["127.0.0.1"] ++ ports) end

    assert_raise Mix.Error, ~r/Unknown option --filters/, fn -> run(~w(--filters x)) end
  end
end
