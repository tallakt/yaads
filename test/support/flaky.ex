defmodule ADS.Test.Flaky do
  @moduledoc false
  # A network that goes wrong, between a client and a device, at random from a seed: it passes the
  # bytes of each connection on in pieces, late, or not for a while; and now and then it drops a
  # connection, or stops passing anything on while keeping it open, as a broken cable does. Once
  # healed, it passes everything on as it comes, the bytes held back included. With healed: true
  # it starts well, until broken.
  use GenServer

  # The chance, for each piece of bytes that comes, of each thing going wrong.
  @split 0.5
  @delay 0.3
  @stall 0.02
  @drop 0.005
  @blackhole 0.003

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def port(flaky), do: GenServer.call(flaky, :port)
  def heal(flaky), do: GenServer.call(flaky, {:healed, true})
  def break(flaky), do: GenServer.call(flaky, {:healed, false})

  # Stalls are longer than the client's timeout, by default.
  @impl true
  def init(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    flaky = self()
    spawn_link(fn -> accept(flaky, listen) end)

    {:ok,
     %{
       port: port,
       upstream: Keyword.fetch!(opts, :upstream),
       seed: Keyword.fetch!(opts, :seed),
       stall: Keyword.get(opts, :stall, 200..500),
       healed: Keyword.get(opts, :healed, false),
       pipes: [],
       count: 0
     }}
  end

  defp accept(flaky, listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pipe = spawn(fn -> pipe(flaky, socket) end)
        :ok = :gen_tcp.controlling_process(socket, pipe)
        send(pipe, :go)
        accept(flaky, listen)

      {:error, _} ->
        :ok
    end
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, s.port, s}

  def handle_call({:healed, healed}, _from, s) do
    for pipe <- s.pipes, do: send(pipe, {:healed, healed})
    {:reply, :ok, %{s | healed: healed}}
  end

  # A connection's pipe, with its own seed; it heals with the rest.
  def handle_call({:pipe, pipe}, _from, s) do
    config = %{upstream: s.upstream, seed: {s.seed, s.count, 7}, healed: s.healed, stall: s.stall}
    {:reply, config, %{s | pipes: [pipe | s.pipes], count: s.count + 1}}
  end

  defp pipe(flaky, client) do
    receive do
      :go -> :ok
    end

    config = GenServer.call(flaky, {:pipe, self()})
    :rand.seed(:exsss, config.seed)
    {host, port} = config.upstream

    case :gen_tcp.connect(host, port, [:binary, active: :once]) do
      {:ok, device} ->
        :ok = :inet.setopts(client, active: :once)
        pass(%{client: client, device: device, healed: config.healed, stall: config.stall})

      {:error, _} ->
        :gen_tcp.close(client)
    end
  end

  # Each piece that comes goes on to the other side, unless something goes wrong with it.
  defp pass(s) do
    receive do
      {:tcp, from, data} ->
        to = if from == s.client, do: s.device, else: s.client

        case fault(s) do
          :drop ->
            close(s)

          :blackhole ->
            blackhole(s, [{to, data}])

          fault ->
            send_on(to, data, fault, s)
            :ok = :inet.setopts(from, active: :once)
            pass(s)
        end

      {:tcp_closed, _} ->
        close(s)

      {:healed, healed} ->
        pass(%{s | healed: healed})
    end
  end

  defp fault(%{healed: true}), do: :none

  defp fault(_s) do
    roll = :rand.uniform()

    cond do
      roll < @drop -> :drop
      roll < @drop + @blackhole -> :blackhole
      roll < @drop + @blackhole + @stall -> :stall
      roll < @drop + @blackhole + @stall + @delay -> :delay
      roll < @drop + @blackhole + @stall + @delay + @split -> :split
      true -> :none
    end
  end

  defp send_on(to, data, :stall, s) do
    Process.sleep(Enum.random(s.stall))
    send_on(to, data, :none, s)
  end

  defp send_on(to, data, :delay, s) do
    Process.sleep(:rand.uniform(30))
    send_on(to, data, :none, s)
  end

  defp send_on(to, data, :split, _s) when byte_size(data) > 1 do
    at = :rand.uniform(byte_size(data) - 1)
    <<first::binary-size(at), rest::binary>> = data
    _ = :gen_tcp.send(to, first)
    Process.sleep(:rand.uniform(3) - 1)
    _ = :gen_tcp.send(to, rest)
  end

  defp send_on(to, data, _none, _s), do: _ = :gen_tcp.send(to, data)

  # Nothing passes until healed, and the connection stays open; then what was held back goes on.
  defp blackhole(s, held) do
    receive do
      {:tcp, from, data} ->
        to = if from == s.client, do: s.device, else: s.client
        :ok = :inet.setopts(from, active: :once)
        blackhole(s, [{to, data} | held])

      {:tcp_closed, _} ->
        close(s)

      {:healed, false} ->
        blackhole(s, held)

      {:healed, true} ->
        for {to, data} <- Enum.reverse(held), do: :gen_tcp.send(to, data)
        _ = :inet.setopts(s.client, active: :once)
        _ = :inet.setopts(s.device, active: :once)
        pass(%{s | healed: true})
    end
  end

  defp close(s) do
    :gen_tcp.close(s.client)
    :gen_tcp.close(s.device)
  end
end
