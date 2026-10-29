defmodule Mix.Tasks.Ads.RouteTest do
  # Mix's shell is the whole VM's, so not async.
  use ExUnit.Case, async: false

  alias ADS.Test.{FakeDiscovery, FakePLC}
  alias Mix.Tasks.Ads.Route

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    # A PLC that lets in only the clients it has routes for, which its UDP port adds.
    plc = start_supervised!({FakePLC, routes: [], system: true})
    udp = start_supervised!({FakeDiscovery, plc: plc})

    ports =
      ~w(--udp-port #{FakeDiscovery.port(udp)} --tcp-port #{FakePLC.port(plc)} --timeout 300)

    %{plc: plc, udp: udp, ports: ports}
  end

  # The task run with the answers to what it asks, in order; and what it said, as {kind, text}.
  defp run(args, answers \\ []) do
    for answer <- answers, do: send(self(), {:mix_shell_input, :prompt, answer})
    Route.run(args)
    said()
  end

  defp said do
    receive do
      {:mix_shell, kind, [text]} -> [{kind, text} | said()]
    after
      0 -> []
    end
  end

  defp host_name, do: :inet.gethostname() |> elem(1) |> List.to_string()

  test "it searches, shows what answers, asks the rest, adds the route, and connects", c do
    said = run(["--search", "127.0.0.1"] ++ c.ports, ["1", "", "1", "", ""])

    assert [
             {:info, "Searching for PLCs..."},
             {:info, "\n  1  CX-FAKE  127.0.0.1  5.36.69.176.1.1\n"},
             {:prompt, "PLC (1-1, or an address) [1]:"},
             {:prompt, "User [Administrator]:"},
             {:prompt, "Password:"},
             {:prompt, "This machine's NetId [127.0.0.1.1.1]:"},
             {:prompt, "Route name [" <> _},
             {:info, "Adding a route on CX-FAKE (127.0.0.1)..."},
             {:info, "Connecting..."},
             {:info, "Connected to Plc30 App 3.1.4026, in run."},
             {:info, snippet}
           ] = said

    assert snippet =~
             ~s|ADS.Client.start_link(host: "127.0.0.1", net_id: "5.36.69.176.1.1", port: #{FakePLC.port(c.plc)})|

    assert FakeDiscovery.routes(c.udp) == [
             %{
               name: host_name(),
               net_id: "127.0.0.1.1.1",
               address: "127.0.0.1",
               user: "Administrator"
             }
           ]
  end

  test "a PLC and options given on the command line aren't asked for, nor with --yes the rest",
       c do
    args = ["127.0.0.1", "--password", "1", "--net-id", "10.0.0.7.1.1", "--name", "scada", "-y"]
    said = run(args ++ c.ports)
    refute Enum.any?(said, &match?({:prompt, _}, &1))
    assert {:info, "Connected to Plc30 App 3.1.4026, in run."} in said
    assert {:info, snippet} = List.last(said)
    assert snippet =~ ~s|local_net_id: "10.0.0.7.1.1"|

    assert [%{name: "scada", net_id: "10.0.0.7.1.1", user: "Administrator"}] =
             FakeDiscovery.routes(c.udp)

    assert [{:info, "Adding a route on CX-FAKE (127.0.0.1)..."}, {:info, _snippet}] =
             run(args ++ ["--no-connect", "--user", "Administrator"] ++ c.ports)
  end

  test "with no PLC answering the search, its address is asked for", c do
    said = run(["--search", "127.0.0.2"] ++ c.ports, ["127.0.0.1", "", "1", "", ""])

    assert [
             {:info, "Searching for PLCs..."},
             {:info, "No PLCs answered. A firewall" <> _},
             {:prompt, "PLC's address:"} | _
           ] = said

    assert [%{net_id: "127.0.0.1.1.1"}] = FakeDiscovery.routes(c.udp)

    assert_raise Mix.Error, ~r/^No PLCs answered/, fn ->
      run(~w(--search 127.0.0.2 -y) ++ c.ports)
    end
  end

  test "answers that don't make sense are asked for again", c do
    answers = ["7", "1", "", "", "1", "1.2.3", "", ""]
    said = run(["--search", "127.0.0.1"] ++ c.ports, answers)
    assert {:error, "Not one of 1-1: 7"} in said
    assert {:error, "Not a NetId, such as 10.0.0.7.1.1: 1.2.3"} in said
    assert Enum.count(said, &(&1 == {:prompt, "Password:"})) == 2
    assert [%{net_id: "127.0.0.1.1.1"}] = FakeDiscovery.routes(c.udp)

    assert_raise Mix.Error, ~r/Not a NetId/, fn ->
      run(~w(127.0.0.1 --password 1 --net-id 1.2.3 -y) ++ c.ports)
    end
  end

  test "with --delete, the route is deleted, asked for as one is added, and no client connects",
       c do
    _ = run(~w(127.0.0.1 --password 1 -y --no-connect) ++ c.ports)
    assert [%{net_id: "127.0.0.1.1.1"}] = FakeDiscovery.routes(c.udp)

    said = run(~w(127.0.0.1 --delete) ++ c.ports, ["", "1", "", ""])

    assert {:info, "Deleting the route " <> _} =
             Enum.find(said, &match?({:info, "Deleting" <> _}, &1))

    assert List.last(said) == {:info, "Deleted."}
    refute Enum.any?(said, &match?({:info, "Connecting..."}, &1))
    assert FakeDiscovery.routes(c.udp) == []

    assert_raise Mix.Error, ~r/refused: :device_invalid_access/, fn ->
      run(~w(127.0.0.1 --delete --password 2 -y) ++ c.ports)
    end
  end

  test "with --list, the PLC's routes, through this machine's route, and no login asked for", c do
    routes = [
      %{name: "scada", net_id: "10.0.0.7.1.1", address: "10.0.0.7"},
      %{name: "APPLICA-1", net_id: "127.0.0.1.1.1", address: "127.0.0.1", flags: 0x40},
      %{name: "temp", net_id: "10.0.0.9.1.1", address: "10.0.0.9", flags: 0x5}
    ]

    plc = start_supervised!({FakePLC, system: true, route_entries: routes}, id: :listing)
    ports = ~w(--udp-port #{FakeDiscovery.port(c.udp)} --tcp-port #{FakePLC.port(plc)})

    assert [{:info, table}] = run(~w(127.0.0.1 --list) ++ ports)

    assert String.split(table, "\n", trim: true) == [
             "  Name       NetId          Address    Flags",
             "  scada      10.0.0.7.1.1   10.0.0.7",
             "  APPLICA-1  127.0.0.1.1.1  127.0.0.1  0x40 (?)",
             "  temp       10.0.0.9.1.1   10.0.0.9   0x5 (temporary, no override)"
           ]

    # Without a route there, nothing can be listed.
    assert_raise Mix.Error,
                 ~r/Couldn't list the routes of CX-FAKE \(127.0.0.1\) \(:closed\)/,
                 fn ->
                   run(~w(127.0.0.1 --list) ++ c.ports)
                 end
  end

  test "a delete looks for the route first, and :device_error is the error unless it was there",
       c do
    add = ~w(127.0.0.1 --password 1 -y --no-connect)

    # There, and gone after, though the answer was :device_error.
    _ = run(add ++ c.ports)
    :ok = FakeDiscovery.set(c.udp, :deleted, 0x700)

    assert List.last(run(~w(127.0.0.1 --delete --password 1 -y) ++ c.ports)) ==
             {:info, "Deleted, though CX-FAKE (127.0.0.1) answered :device_error."}

    assert FakeDiscovery.routes(c.udp) == []

    # Not among the routes this machine sees there: nothing is sent.
    _ = run(add ++ ~w(--name plain) ++ c.ports)

    assert_raise Mix.Error, ~r/has no route named nothing; nothing deleted/, fn ->
      run(~w(127.0.0.1 --delete --password 1 -y --name nothing) ++ c.ports)
    end

    assert [%{name: "plain"}] = FakeDiscovery.routes(c.udp)

    # With no route there for this machine, nothing to look with: the answer is as it comes, and
    # :ok doesn't tell whether there was one to delete.
    :ok = FakeDiscovery.set(c.udp, :deleted, 0)
    _ = run(~w(127.0.0.1 --delete --password 1 -y --name plain) ++ c.ports)
    :ok = FakeDiscovery.set(c.udp, :missing, 0)

    assert {:info, "CX-FAKE (127.0.0.1) answered :ok, but this machine has no route there" <> _} =
             List.last(run(~w(127.0.0.1 --delete --password 1 -y --name plain) ++ c.ports))

    :ok = FakeDiscovery.set(c.udp, :missing, 0x700)

    assert_raise Mix.Error,
                 ~r/refused: :device_error. TwinCAT answers so for a route it hasn't/,
                 fn -> run(~w(127.0.0.1 --delete --password 1 -y --name plain) ++ c.ports) end
  end

  test "a wrong password is refused, and no route added", c do
    assert_raise Mix.Error, ~r/refused: :device_invalid_access/, fn ->
      run(~w(127.0.0.1 --password 2 -y) ++ c.ports)
    end

    assert FakeDiscovery.routes(c.udp) == []
  end

  test "a PLC that doesn't answer, or doesn't let the client in after all, says so", c do
    assert_raise Mix.Error, ~r/No answer from 127.0.0.1 on UDP port \d+ \(:timeout\)/, fn ->
      :ok = FakeDiscovery.set(c.udp, :mode, :silent)
      run(~w(127.0.0.1 --password 1 -y) ++ c.ports)
    end

    # A route on another PLC than the one connected to.
    other = start_supervised!({FakeDiscovery, []}, id: :other)
    ports = ~w(--udp-port #{FakeDiscovery.port(other)} --tcp-port #{FakePLC.port(c.plc)})

    assert_raise Mix.Error, ~r/The route was added, but connecting failed: :closed/, fn ->
      run(~w(127.0.0.1 --password 1 -y) ++ ports)
    end
  end

  test "an unknown option, or more than one PLC, is an error", c do
    assert_raise Mix.Error, ~r/Unknown option --pasword/, fn -> run(~w(--pasword 1)) end
    assert_raise Mix.Error, ~r/at most one PLC/, fn -> run(~w(10.0.0.5 10.0.0.6) ++ c.ports) end
  end
end
