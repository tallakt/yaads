defmodule ADS.LeakTest do
  # A PLC has only so many handles and notifications, and a client that loses track of some uses
  # them up in time, on a line that runs for months. Whatever a client is asked to do, here at
  # random, the PLC must hold the notifications of its subscriptions, no more and no fewer, and
  # only handles the client has; and once it stops, nothing at all.
  #
  # Each check waits for the client to settle, as a handle it's just been given is kept a moment
  # later; the client's handles are looked at in its state.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ADS.Client
  alias ADS.Test.FakePLC

  @names ~w(MAIN.nCounter MAIN.nSpeed MAIN.bOn MAIN.stPump MAIN.aValues MAIN.eMode MAIN.nNone)

  defp runs, do: max(div(Application.get_env(:stream_data, :max_runs, 100), 10), 10)

  defp names, do: uniq_list_of(member_of(@names), min_length: 1, max_length: 3)

  defp step do
    frequency([
      {3, tuple({constant(:read), member_of(@names)})},
      {2, tuple({constant(:read_many), names()})},
      {4, tuple({constant(:subscribe), names(), member_of([:on_change, :cyclic])})},
      {2, tuple({constant(:unsubscribe), integer(0..9)})},
      {2, tuple({constant(:exit), integer(0..9)})},
      {1, constant(:online_change)},
      {1, constant(:drop)}
    ])
  end

  # A subscriber that takes whatever comes, until told to stop.
  # A subscriber that takes whatever comes, until told to stop, and counts the targets it's told
  # are left out, as when a handle goes stale again within a second of the last time.
  defp subscriber do
    spawn(fn -> take(0) end)
  end

  defp take(lost) do
    receive do
      :stop -> :ok
      {:lost?, from} -> send(from, {:lost, self(), lost}) && take(lost)
      {Client, _ref, {:error, _target, _reason}} -> take(lost + 1)
      _ -> take(lost)
    end
  end

  defp wanted(subs) do
    for {_ref, pid, n} <- subs, reduce: 0 do
      sum ->
        send(pid, {:lost?, self()})

        receive do
          {:lost, ^pid, lost} -> sum + n - lost
        after
          1000 -> flunk("a subscriber didn't answer")
        end
    end
  end

  # Each step, and the subscriptions there are after it, as {ref, subscriber, notifications}.
  defp step(c, {:read, name}, subs) do
    _ = Client.read(c.client, name)
    subs
  end

  defp step(c, {:read_many, names}, subs) do
    _ = Client.read_many(c.client, names)
    subs
  end

  defp step(c, {:subscribe, names, mode}, subs) do
    pid = subscriber()

    case Client.subscribe(c.client, names, mode: mode, cycle_time: 20, to: pid) do
      {:ok, ref} -> subs ++ [{ref, pid, length(names)}]
      {:error, _} -> send(pid, :stop) && subs
    end
  end

  defp step(c, {:unsubscribe, i}, subs) when subs != [] do
    {ref, pid, _} = sub = Enum.at(subs, rem(i, length(subs)))
    :ok = Client.unsubscribe(c.client, ref)
    send(pid, :stop)
    List.delete(subs, sub)
  end

  defp step(_c, {:exit, i}, subs) when subs != [] do
    {_ref, pid, _} = sub = Enum.at(subs, rem(i, length(subs)))
    Process.exit(pid, :kill)
    List.delete(subs, sub)
  end

  defp step(c, :online_change, subs) do
    :ok = FakePLC.online_change(c.plc)
    subs
  end

  # Until the PLC has seen the connection go, and the client is back on another.
  defp step(c, :drop, subs) do
    gone = length(FakePLC.leftovers(c.plc)) + 1
    :ok = FakePLC.drop_connections(c.plc)

    assert eventually(fn ->
             length(FakePLC.leftovers(c.plc)) == gone and FakePLC.connections(c.plc) != [] and
               Client.status(c.client) == :connected
           end)

    subs
  end

  defp step(_c, _no_subscription, subs), do: subs

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp settled?(c, notifications) do
    plc = :sys.get_state(c.plc)
    handles = for {_key, %{handle: handle}} <- :sys.get_state(c.client).handles, do: handle

    map_size(plc.notifications) == notifications and
      Enum.all?(plc.handles, fn {handle, v} ->
        v.owner not in plc.connections or handle in handles
      end)
  end

  # As long as FUZZ_RUNS makes it.
  @tag timeout: :infinity
  property "the PLC holds the notifications of the client's subscriptions, and none once it stops" do
    check all steps <- list_of(step(), min_length: 1, max_length: 25), max_runs: runs() do
      id = make_ref()
      plc = start_supervised!({FakePLC, []}, id: id)

      client =
        start_supervised!(
          {Client,
           host: "127.0.0.1",
           port: FakePLC.port(plc),
           net_id: "5.36.69.176.1.1",
           backoff: {10, 20}},
          id: make_ref(),
          restart: :temporary
        )

      c = %{plc: plc, client: client}

      assert eventually(fn ->
               FakePLC.connections(plc) != [] and Client.status(client) == :connected
             end)

      subs =
        Enum.reduce(steps, [], fn step, subs ->
          subs = step(c, step, subs)

          assert eventually(fn -> settled?(c, wanted(subs)) end),
                 "after #{inspect(step)}: #{FakePLC.notifications(plc)} notifications, not " <>
                   "#{wanted(subs)}, or handles the client hasn't"

          subs
        end)

      [connection] = FakePLC.connections(plc)
      :ok = Client.stop(client)
      assert eventually(fn -> List.keymember?(FakePLC.leftovers(plc), connection, 0) end)

      assert {_, %{handles: 0, notifications: 0}} =
               List.keyfind(FakePLC.leftovers(plc), connection, 0)

      for {_ref, pid, _} <- subs, do: send(pid, :stop)
      :ok = stop_supervised(id)
    end
  end
end
