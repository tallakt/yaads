defmodule Mix.Tasks.Ads.InfoTest do
  # Mix's shell is the whole VM's, so not async.
  use ExUnit.Case, async: false

  alias ADS.Test.{FakeDiscovery, FakePLC}
  alias Mix.Tasks.Ads.Info

  @adapters [
    %{
      description: "TwinCAT-Intel PCI Ethernet Adapter (Gigabit)",
      mac: <<0, 1, 5, 0x76, 0x34, 0xAE>>,
      addresses: [{{10, 0, 0, 5}, {255, 255, 255, 0}}, {{10, 0, 0, 6}, {255, 255, 0, 0}}],
      gateways: [{10, 0, 0, 1}]
    },
    %{description: "Ethernet #2", mac: <<0, 1, 5, 0x76, 0x34, 0xAF>>, dhcp: true}
  ]

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    plc =
      start_supervised!(
        {FakePLC,
         system: true,
         host_name: "CX-1234AB",
         adapters: @adapters,
         hosts: %{"scada-1" => {10, 0, 0, 7}}}
      )

    udp = start_supervised!({FakeDiscovery, plc: plc})
    ports = ~w(--udp-port #{FakeDiscovery.port(udp)} --tcp-port #{FakePLC.port(plc)})
    %{plc: plc, udp: udp, ports: ports}
  end

  defp run(args) do
    Info.run(args)
    said()
  end

  defp said do
    receive do
      {:mix_shell, kind, [text]} -> [{kind, IO.chardata_to_string(text)} | said()]
    after
      0 -> []
    end
  end

  test "its version and state, host name and adapters", c do
    assert [{:info, "CX-FAKE (127.0.0.1), 5.36.69.176.1.1\n"}, {:info, text}] =
             run(["127.0.0.1"] ++ c.ports)

    assert String.split(text, "\n") == [
             "  TwinCAT System 3.1.4026, in run",
             "",
             "  Host name  CX-1234AB",
             "",
             "  Adapter                                       MAC                DHCP  Addresses",
             "  TwinCAT-Intel PCI Ethernet Adapter (Gigabit)  00:01:05:76:34:AE  no    10.0.0.5/24",
             String.duplicate(" ", 73) <> "10.0.0.6/16",
             String.duplicate(" ", 73) <> "gateway 10.0.0.1",
             "  Ethernet #2                                   00:01:05:76:34:AF  yes   -",
             ""
           ]
  end

  test "only what's asked for, and names looked up on the PLC", c do
    assert [_, {:info, "  Host name  CX-1234AB\n"}] = run(~w(127.0.0.1 --host-name) ++ c.ports)

    assert [_, {:info, text}] =
             run(~w(127.0.0.1 --resolve scada-1 --resolve nowhere.invalid) ++ c.ports)

    assert text == "  scada-1          10.0.0.7\n  nowhere.invalid  not found\n"

    assert [_, {:info, text}] = run(~w(127.0.0.1 --state --resolve scada-1) ++ c.ports)
    assert text == "  TwinCAT System 3.1.4026, in run\n\n  scada-1  10.0.0.7\n"
  end

  test "the PLC's strings in the code page given", c do
    plc =
      start_supervised!({FakePLC, system: true, host_name: "Пульт-1", codepage: :windows_1251},
        id: :cyrillic
      )

    ports = ~w(--udp-port #{FakeDiscovery.port(c.udp)} --tcp-port #{FakePLC.port(plc)})

    assert [_, {:info, "  Host name  Пульт-1\n"}] =
             run(~w(127.0.0.1 --host-name --codepage windows-1251) ++ ports)

    assert_raise Mix.Error, ~r/No code page :windows_932/, fn ->
      run(~w(127.0.0.1 --codepage windows-932) ++ ports)
    end
  end

  test "a PLC without a route for this machine, and wrong options, say so", c do
    plc = start_supervised!({FakePLC, system: true, routes: []}, id: :closed)
    ports = ~w(--udp-port #{FakeDiscovery.port(c.udp)} --tcp-port #{FakePLC.port(plc)})

    assert_raise Mix.Error,
                 ~r/No answer from CX-FAKE \(127.0.0.1\) over ADS \(:closed\).*mix ads.route/,
                 fn ->
                   run(["127.0.0.1"] ++ ports)
                 end

    assert_raise Mix.Error, ~r/Unknown option --adapter/, fn -> run(~w(--adapter)) end
  end
end
