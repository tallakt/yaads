defmodule ADS.Test.FakeDiscovery do
  @moduledoc false
  # A TwinCAT router's UDP port as far as the tests need it, on 127.0.0.1 and a port of its own:
  # it gives its info, and adds routes for the user and password it's started with. Played from
  # Beckhoff's ADS library, as ADS.Discovery reads it; a real PLC is the test of both.
  #
  # Told to, it answers with junk first, from elsewhere, for another service, or not at all. With
  # plc:, a fake PLC started with routes:, the routes it adds let clients in to that PLC, and those
  # it deletes no longer. It deletes a route by its name, as TwinCAT 3.1 4026 does, and one it
  # hasn't is 0x70C, not found, as Beckhoff's own system service answers.
  use GenServer

  alias ADS.Discovery

  @net_id <<5, 36, 69, 176, 1, 1>>

  def net_id, do: @net_id

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def port(fake), do: GenServer.call(fake, :port)
  def routes(fake), do: GenServer.call(fake, :routes)
  def set(fake, key, value), do: GenServer.call(fake, {:set, key, value})

  @impl true
  def init(opts) do
    {:ok, socket} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: true])
    {:ok, other} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)

    {:ok,
     %{
       socket: socket,
       other: other,
       port: port,
       user: Keyword.get(opts, :user, "Administrator"),
       password: Keyword.get(opts, :password, "1"),
       plc: Keyword.get(opts, :plc),
       routes: [],
       # :answer, :silent, :junk_first, :no_result, :twice
       mode: :answer
     }}
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, s.port, s}
  def handle_call(:routes, _from, s), do: {:reply, Enum.reverse(s.routes), s}
  def handle_call({:set, key, value}, _from, s), do: {:reply, :ok, Map.put(s, key, value)}

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = s) do
    case Discovery.decode(data) do
      {:ok, %{service: service} = request} when service in [1, 6, 7] ->
        {answer, s} = handle(request, s)
        answer(s, {ip, port}, request, answer)
        {:noreply, s}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # The SHA-256 of nothing, as a certificate's, in lower case as TwinCAT gives it.
  @fingerprint "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # As TwinCAT 3.1 4026 answers, its tag 4, the OS's version, left out.
  defp handle(%{service: 1}, s),
    do:
      {[{5, "CX-FAKE" <> <<0>>}, {3, <<3, 1, 4026::16-little>>}, {18, @fingerprint <> <<0>>}], s}

  defp handle(%{service: 6, tags: tags}, s) do
    tag = fn id -> tags |> List.keyfind(id, 0, {id, ""}) |> elem(1) |> cstring() end

    if tag.(13) == s.user and tag.(2) == s.password do
      route = %{
        name: tag.(12),
        net_id: tags |> List.keyfind(7, 0) |> elem(1) |> ADS.NetId.to_string(),
        address: tag.(5),
        user: tag.(13)
      }

      if s.plc, do: :ok = ADS.Test.FakePLC.add_route(s.plc, route.net_id)
      {[{1, <<0::32>>}], %{s | routes: [route | s.routes]}}
    else
      {[{1, <<0x704::32-little>>}], s}
    end
  end

  defp handle(%{service: 7, tags: tags}, s) do
    tag = fn id -> tags |> List.keyfind(id, 0, {id, ""}) |> elem(1) |> cstring() end
    {gone, routes} = Enum.split_with(s.routes, &(&1.name == tag.(12)))

    cond do
      tag.(13) != s.user or tag.(2) != s.password ->
        {[{1, <<0x704::32-little>>}], s}

      gone == [] ->
        {[{1, <<0x70C::32-little>>}], s}

      true ->
        # A NetId another route has still gets in.
        for %{net_id: net_id} <- gone,
            s.plc != nil and not Enum.any?(routes, &(&1.net_id == net_id)),
            do: :ok = ADS.Test.FakePLC.delete_route(s.plc, net_id)

        {[{1, <<0::32>>}], %{s | routes: routes}}
    end
  end

  defp cstring(value), do: value |> :binary.split(<<0>>) |> hd()

  defp answer(%{mode: :silent}, _to, _request, _tags), do: :ok

  defp answer(%{mode: :junk_first} = s, {ip, port} = to, request, tags) do
    # From another port, for another service, with another invoke id, and not one at all.
    send_to(s.other, to, reply(request, tags))
    send_to(s.socket, to, reply(%{request | service: 99}, tags))
    send_to(s.socket, to, reply(Map.put(request, :invoke_id, 7), tags))
    :ok = :gen_udp.send(s.socket, ip, port, "junk")
    answer(%{s | mode: :answer}, to, request, tags)
  end

  defp answer(%{mode: :no_result} = s, to, request, _tags),
    do: send_to(s.socket, to, reply(request, [{3, "x"}]))

  defp answer(%{mode: :twice} = s, to, request, tags) do
    send_to(s.socket, to, reply(request, tags))
    send_to(s.socket, to, %{reply(request, tags) | net_id: <<10, 0, 0, 9, 1, 1>>})
  end

  defp answer(s, to, request, tags), do: send_to(s.socket, to, reply(request, tags))

  defp reply(request, tags) do
    %{
      service: Bitwise.bor(0x80000000, request.service),
      invoke_id: Map.get(request, :invoke_id, 0),
      net_id: @net_id,
      port: 10000,
      tags: tags
    }
  end

  defp send_to(socket, {ip, port}, datagram),
    do: :ok = :gen_udp.send(socket, ip, port, Discovery.encode(datagram))
end
