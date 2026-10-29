defmodule ADS.FlakyTest do
  # A client on a network that goes wrong at random, as test/support/flaky.ex has it: every
  # request still has its result in time, the right one or an error, never another's; and once
  # the network is well again, so is the client, its notifications included.
  #
  # It times each request, so a machine that's slow or busy can fail it while the client isn't
  # wrong; it runs only when asked: mix test --only realtime.
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :realtime

  alias ADS.{Client, Symbol, Type}
  alias ADS.Test.{FakePLC, Flaky}

  @timeout 150
  # What scheduling may add to a request's timeout, here.
  @slack 150

  @values %{
    "MAIN.nCounter" => 123_456,
    "MAIN.nSpeed" => -1500,
    "MAIN.bOn" => true,
    "MAIN.fTemp" => 21.5,
    "MAIN.sName" => "Pump 1",
    "MAIN.aValues" => [1, 2, 3, 4, 5],
    "MAIN.stPump" => %{
      "nSpeed" => 7,
      "fTemp" => -1.5,
      "bRunning" => true,
      "eMode" => "eAuto",
      "sTag" => "P1"
    }
  }

  @names Map.keys(@values)

  # A twentieth as many runs as the other properties: each takes a second or so.
  defp runs, do: max(div(Application.get_env(:stream_data, :max_runs, 100), 20), 5)

  defp type(name) do
    {_, _, type, _, _} = Enum.find(FakePLC.variables(), &(elem(&1, 0) == name))
    type
  end

  # A request, and how many requests to the device it may take, each within the timeout.
  defp request do
    one_of([
      tuple({constant(:address), member_of(@names)}),
      tuple({constant(:typed), member_of(@names)}),
      tuple({constant(:name), member_of(@names)}),
      tuple({constant(:many), uniq_list_of(member_of(@names), min_length: 1, max_length: 4)})
    ])
  end

  defp requests_to_device({:address, _}), do: 1
  defp requests_to_device({:typed, _}), do: 2
  defp requests_to_device(_by_name), do: 8

  defp run({:address, name}, client, symbols) do
    %Symbol{index_group: group, index_offset: offset, size: size} = symbols[name]

    case Client.request(client, {:read, group, offset, size}) do
      {:ok, data} -> Type.decode(type(name), data)
      error -> error
    end
  end

  defp run({:typed, name}, client, _symbols), do: Client.read(client, name, type: type(name))
  defp run({:name, name}, client, _symbols), do: Client.read(client, name)
  defp run({:many, names}, client, _symbols), do: Client.read_many(client, names)

  defp expected({:many, names}), do: {:ok, for(name <- names, do: {:ok, @values[name]})}
  defp expected({_kind, name}), do: {:ok, @values[name]}

  defp right_or_error?({:many, names}, {:ok, results}) do
    length(results) == length(names) and
      Enum.all?(Enum.zip(names, results), fn {name, result} ->
        right_or_error?({:name, name}, result)
      end)
  end

  defp right_or_error?(request, result),
    do: result == expected(request) or result in [{:error, :timeout}, {:error, :closed}]

  # As long as FUZZ_RUNS makes it.
  @tag timeout: :infinity
  property "on a network that goes wrong, each request has its result in time, the right one or an error" do
    check all seed <- integer(),
              workers <- list_of(list_of(request(), length: 8), length: 4),
              max_runs: runs() do
      ids = %{plc: make_ref(), flaky: make_ref(), client: make_ref()}
      plc = start_supervised!({FakePLC, []}, id: ids.plc)
      for {name, value} <- @values, do: :ok = FakePLC.put(plc, name, value)
      {:ok, symbols} = Symbol.decode_all(FakePLC.symbol_upload())
      symbols = Map.new(symbols, &{&1.name, &1})

      flaky =
        start_supervised!(
          {Flaky, upstream: {~c"127.0.0.1", FakePLC.port(plc)}, seed: seed, healed: true},
          id: ids.flaky
        )

      client =
        start_supervised!(
          {Client,
           host: "127.0.0.1",
           port: Flaky.port(flaky),
           net_id: "5.36.69.176.1.1",
           timeout: @timeout,
           backoff: {10, 50}},
          id: ids.client
        )

      assert {:ok, ref} = Client.subscribe(client, "MAIN.nCounter")
      :ok = Flaky.break(flaky)

      done =
        workers
        |> Enum.map(fn requests ->
          Task.async(fn ->
            for request <- requests do
              {us, result} = :timer.tc(fn -> run(request, client, symbols) end)
              {request, result, div(us, 1000)}
            end
          end)
        end)
        |> Task.await_many(60_000)
        |> Enum.concat()

      for {request, result, ms} <- done do
        assert right_or_error?(request, result),
               "#{inspect(request)} gave #{inspect(result)}"

        assert ms <= requests_to_device(request) * (@timeout + @slack),
               "#{inspect(request)} took #{ms} ms"
      end

      :ok = Flaky.heal(flaky)

      # Well again: each request right, and a change notified.
      assert Enum.any?(1..100, fn _ ->
               Enum.all?(done, fn {request, _, _} ->
                 run(request, client, symbols) == expected(request)
               end) or (Process.sleep(20) && false)
             end)

      assert Enum.any?(1..50, fn i ->
               :ok = FakePLC.put(plc, "MAIN.nCounter", i)

               receive do
                 {Client, ^ref, {:value, "MAIN.nCounter", ^i, _}} -> true
               after
                 40 -> false
               end
             end)

      for id <- [ids.client, ids.flaky, ids.plc], do: :ok = stop_supervised(id)
    end
  end
end
