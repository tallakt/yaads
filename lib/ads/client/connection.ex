defmodule ADS.Client.Connection do
  @moduledoc false
  # A connection to an AMS router, over TCP or Secure ADS: requests on the way, up to max_pending
  # at once, each under an invoke id of its own; the device notifications that come in, passed to
  # their subscribers; and the handles and types that the client has looked up, kept for as long as
  # the connection lasts. Connecting takes a process of its own, and so does adding a subscription's
  # notifications again after a reconnect, which goes through the client's own functions.
  use GenServer

  alias ADS.{AMS, Command, NetId, ReturnCode, Secure, Type}

  @notification 8
  @service_not_supported 0x701

  # Notifications the client didn't ask for, which it asks the device to delete, once each.
  @max_orphans 1000

  @options [
    :binary,
    packet: :raw,
    active: false,
    nodelay: true,
    keepalive: true,
    # A send that blocks for so long means the connection is gone, though a sum write may be big.
    send_timeout: 5000,
    send_timeout_close: true
  ]

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    s =
      Map.merge(config, %{
        socket: nil,
        framing: if(config.secure, do: :tls, else: :tcp),
        connector: nil,
        status: :connecting,
        buffer: <<>>,
        local: config.local_net_id,
        remote: config.net_id,
        next: 1,
        pending: %{},
        queue: :queue.new(),
        heard: now(),
        silent: nil,
        delay: elem(config.backoff, 0),
        subscriptions: %{},
        notifications: %{},
        orphans: MapSet.new(),
        handles: %{},
        types: %{}
      })

    {:ok, connect(s)}
  end

  @impl true
  def handle_call({:request, port, request, encoded, timeout, tag}, from, s),
    do:
      {:noreply,
       submit(s, entry(port(port, s), request, encoded, timeout, {:call, from}, tag, s))}

  def handle_call(:status, _from, s), do: {:reply, s.status, s}

  def handle_call(:info, _from, s) do
    info = %{
      status: s.status,
      local: s.local && {NetId.to_string(s.local), s.local_ams_port},
      remote: s.remote && {NetId.to_string(s.remote), s.ams_port}
    }

    {:reply, info, s}
  end

  def handle_call({:handles, port, names}, _from, s) do
    port = port(port, s)

    {:reply,
     for(
       name <- names,
       Map.has_key?(s.handles, {port, name}),
       into: %{},
       do: {name, s.handles[{port, name}]}
     ), s}
  end

  # Another caller may have looked the same name up meanwhile: the first handle stays, and the one
  # whose handle didn't is told to let its own go.
  def handle_call({:remember, port, name, handle, type}, _from, s) do
    key = {port(port, s), name}

    case s.handles do
      %{^key => %{handle: ^handle} = entry} ->
        {:reply, {:ok, handle}, put_in(s.handles[key], %{entry | type: type || entry.type})}

      %{^key => %{handle: existing} = entry} ->
        {:reply, {:existing, existing},
         put_in(s.handles[key], %{entry | type: entry.type || type})}

      _ when s.status == :connected ->
        {:reply, {:ok, handle}, put_in(s.handles[key], %{handle: handle, type: type})}

      # A handle from a connection that has since dropped is no good.
      _ ->
        {:reply, {:error, :closed}, s}
    end
  end

  def handle_call({:forget, port, name}, _from, s),
    do: {:reply, :ok, %{s | handles: Map.delete(s.handles, {port(port, s), name})}}

  def handle_call({:type, port, name}, _from, s),
    do: {:reply, Map.fetch(s.types, {port(port, s), name}), s}

  def handle_call({:remember_type, port, name, type}, _from, s),
    do: {:reply, :ok, put_in(s.types[{port(port, s), name}], type)}

  def handle_call({:subscribe, to}, _from, s) do
    ref = make_ref()
    subscription = %{to: to, monitor: Process.monitor(to), targets: %{}}
    {:reply, ref, put_in(s.subscriptions[ref], subscription)}
  end

  def handle_call({:unsubscribe, ref}, _from, s), do: {:reply, :ok, unsubscribe(s, ref)}

  @impl true
  def handle_cast({:request, port, request, encoded, timeout, to, ref}, s),
    do:
      {:noreply,
       submit(s, entry(port(port, s), request, encoded, timeout, {:send, to, ref}, nil, s))}

  def handle_cast({:lost, ref, key, reason}, s), do: {:noreply, lost(s, ref, key, reason)}

  @impl true
  def handle_info({:connected, connector, socket, info}, %{connector: connector} = s) do
    s = %{
      s
      | socket: socket,
        connector: nil,
        status: :connected,
        buffer: info.buffer,
        local: info.local,
        remote: s.net_id || info.remote,
        heard: now(),
        orphans: MapSet.new()
    }

    # A route is added once; the next connections use it.
    s = if s.secure, do: put_in(s.secure.add_route, nil), else: s

    case setopts(s, active: :once) do
      :ok -> {:noreply, s |> resubscribe() |> frames()}
      {:error, reason} -> {:noreply, drop(s, reason)}
    end
  end

  def handle_info({:connect_failed, connector, reason}, %{connector: connector} = s),
    do: {:noreply, drop(%{s | connector: nil}, reason)}

  def handle_info(:reconnect, %{status: {:disconnected, _}} = s), do: {:noreply, connect(s)}

  def handle_info({protocol, socket, data}, %{socket: socket} = s) when protocol in [:tcp, :ssl],
    do: {:noreply, frames(%{s | buffer: s.buffer <> data})}

  def handle_info({closed, socket}, %{socket: socket} = s)
      when closed in [:tcp_closed, :ssl_closed],
      do: {:noreply, drop(s, :closed)}

  def handle_info({error, socket, reason}, %{socket: socket} = s)
      when error in [:tcp_error, :ssl_error],
      do: {:noreply, drop(s, reason)}

  def handle_info({:expire, id}, s), do: {:noreply, expire(s, id)}

  def handle_info({:EXIT, connector, reason}, %{connector: connector} = s) when reason != :normal,
    do: {:noreply, drop(%{s | connector: nil}, reason)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, s) do
    case Enum.find(s.subscriptions, fn {_ref, subscription} -> subscription.monitor == monitor end) do
      {ref, _subscription} -> {:noreply, unsubscribe(s, ref)}
      nil -> {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # What the client does on the way out takes a second at most.
  @linger 1000

  @impl true
  def terminate(_reason, s) do
    if s.connector, do: Process.exit(s.connector, :kill)

    if s.socket do
      deadline = System.monotonic_time(:millisecond) + @linger
      s = adding(%{s | queue: :queue.new()}, deadline)
      _ = if s.socket && let_go(s) > 0, do: linger(s, deadline)
      if s.socket, do: close(s)
    end
  end

  # Notifications on the way, as added again after an online change, are waited for, to be let go
  # of with the rest.
  defp adding(%{socket: socket} = s, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 and
         Enum.any?(s.pending, fn {_, e} -> match?({:notification, _, _}, e.tag) end) do
      receive do
        {protocol, ^socket, data} when protocol in [:tcp, :ssl] ->
          adding(frames(%{s | buffer: s.buffer <> data}), deadline)

        {closed, ^socket} when closed in [:tcp_closed, :ssl_closed] ->
          %{s | socket: nil}
      after
        remaining -> s
      end
    else
      s
    end
  end

  # Closed at once, a connection loses what was just sent on it: the device's answers to a closed
  # socket are met with a reset, which throws away whatever the device hadn't read yet. So the
  # client stops sending, and reads until the device closes too.
  defp linger(s, deadline) do
    _ = shutdown(s)
    drain(s, deadline)
  end

  defp drain(%{socket: socket} = s, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         :ok <- setopts(s, active: :once) do
      receive do
        {protocol, ^socket, _data} when protocol in [:tcp, :ssl] -> drain(s, deadline)
        {closed, ^socket} when closed in [:tcp_closed, :ssl_closed] -> :ok
        {error, ^socket, _reason} when error in [:tcp_error, :ssl_error] -> :ok
      after
        remaining -> :ok
      end
    end
  end

  defp port(nil, s), do: s.ams_port
  defp port(port, _s), do: port

  defp entry(port, request, {command, data}, timeout, reply, tag, s) do
    %{
      id: make_ref(),
      port: port,
      request: request,
      command: command,
      data: data,
      timeout: timeout || s.timeout,
      reply: reply,
      tag: tag,
      timer: nil,
      sent: nil
    }
  end

  defp submit(%{status: {:disconnected, _}} = s, entry) do
    reply(entry, {:error, :closed})
    s
  end

  defp submit(s, entry) do
    timer = Process.send_after(self(), {:expire, entry.id}, entry.timeout)
    flush(%{s | queue: :queue.in(%{entry | timer: timer}, s.queue)})
  end

  # A request of the client's own, whose answer nobody waits for.
  defp submit_own(s, port, request),
    do: submit(s, entry(port, request, Command.encode_request(request), nil, :ignore, nil, s))

  # Sends what waits, as far as max_pending allows.
  defp flush(%{status: :connected} = s) when map_size(s.pending) < s.max_pending do
    case :queue.out(s.queue) do
      {{:value, entry}, queue} ->
        {invoke, next} = invoke_id(s.next, s.pending)

        case send_data(s, AMS.encode(packet(s, entry, invoke), s.framing)) do
          :ok ->
            pending = Map.put(s.pending, invoke, %{entry | sent: now()})
            flush(%{s | queue: queue, pending: pending, next: next})

          {:error, reason} ->
            drop(%{s | queue: :queue.in_r(entry, queue)}, reason)
        end

      {:empty, _queue} ->
        s
    end
  end

  defp flush(s), do: s

  defp packet(s, entry, invoke) do
    %AMS{
      target: s.remote,
      target_port: entry.port,
      source: s.local,
      source_port: s.local_ams_port,
      command: entry.command,
      invoke_id: invoke,
      data: entry.data
    }
  end

  # Given out in turn, so that a late answer can't be taken for a newer request's.
  defp invoke_id(id, pending) do
    next = if id == 0xFFFFFFFF, do: 1, else: id + 1
    if Map.has_key?(pending, id), do: invoke_id(next, pending), else: {id, next}
  end

  # A packet's handling may have dropped the connection, when an answer to it couldn't be sent.
  defp frames(%{socket: nil} = s), do: s

  defp frames(s) do
    case AMS.decode(s.buffer, s.framing, s.max_size) do
      # Only a whole packet shows the device is there: a trickle of bytes doesn't keep a dead
      # connection open.
      {:ok, packet, rest} ->
        frames(packet(%{s | buffer: rest, heard: now()}, packet))

      {:discard, rest} ->
        frames(%{s | buffer: rest, heard: now()})

      :more ->
        case setopts(s, active: :once) do
          :ok -> flush(s)
          {:error, reason} -> drop(s, reason)
        end

      {:error, :invalid_length} ->
        drop(s, :invalid_frame)
    end
  end

  # A notification is one whatever its flags say, as some devices mark them as responses: the
  # client never sends one, so it can't be an answer.
  defp packet(s, packet) do
    cond do
      packet.command == @notification -> notification(s, packet)
      AMS.response?(packet) -> answer(s, packet)
      true -> refuse(s, packet)
    end
  end

  # The invoke id matches an answer to its request, and the command must be the request's. An
  # error in the AMS header is a router's, or a device's that wouldn't take the request at all.
  defp answer(s, packet) do
    case Map.fetch(s.pending, packet.invoke_id) do
      {:ok, %{command: command} = entry} when command == packet.command ->
        _ = Process.cancel_timer(entry.timer)

        result =
          if packet.error_code != 0,
            do: {:error, ReturnCode.name(packet.error_code)},
            else: Command.decode_response(entry.request, packet.data)

        s = %{s | pending: Map.delete(s.pending, packet.invoke_id), delay: elem(s.backoff, 0)}
        settle(s, entry, result)

      _ ->
        s
    end
  end

  # A notification is registered as its answer comes, before any of its samples can.
  defp settle(s, %{tag: {:notification, ref, info}} = entry, {:ok, handle}) do
    case s.subscriptions do
      %{^ref => subscription} ->
        reply(entry, {:ok, handle})
        info = %{info | handle: handle, port: entry.port}
        s = put_in(s.subscriptions[ref].targets, Map.put(subscription.targets, info.key, info))
        %{s | notifications: Map.put(s.notifications, {entry.port, handle}, {ref, info.key})}

      _ ->
        reply(entry, {:error, :closed})
        submit_own(s, entry.port, {:delete_notification, handle})
    end
  end

  defp settle(s, entry, result) do
    reply(entry, result)
    s
  end

  defp notification(s, packet) do
    case Command.decode_notification(packet.data) do
      {:ok, stamps} ->
        for {time, samples} <- stamps, {handle, data} <- samples, reduce: s do
          s -> sample(s, packet.source_port, time, handle, data)
        end

      :error ->
        s
    end
  end

  defp sample(s, port, time, handle, data) do
    with {:ok, {ref, key}} <- Map.fetch(s.notifications, {port, handle}),
         {:ok, %{to: to, targets: %{^key => info}}} <- Map.fetch(s.subscriptions, ref) do
      if data == <<>> do
        gone(s, port, handle, ref, info)
      else
        send(to, {ADS.Client, ref, message(info, data, time)})
        s
      end
    else
      _ -> orphan(s, port, handle)
    end
  end

  defp message(info, data, time) do
    case Type.decode(info.type, data) do
      {:ok, value} -> {:value, info.target, value, time}
      :error -> {:error, info.target, {:invalid_response, data}}
    end
  end

  # A sample without data: the variable's handle is no longer good, as after an online change. The
  # notification is added again with a new one, unless that happened less than a second ago.
  defp gone(s, port, handle, ref, info) do
    s = %{s | notifications: Map.delete(s.notifications, {port, handle})}
    s = submit_own(s, port, {:delete_notification, handle})
    s = if info.symbol, do: %{s | handles: Map.delete(s.handles, {port, info.symbol})}, else: s
    at = System.monotonic_time(:millisecond)

    if info.at != nil and at - info.at < 1000 do
      lost(s, ref, info.key, :device_notify_handle_invalid)
    else
      info = %{info | handle: nil, at: at}
      s = put_in(s.subscriptions[ref].targets[info.key], info)
      connection = self()
      spawn(fn -> ADS.Client.reestablish(connection, ref, info) end)
      s
    end
  end

  # A target whose notification couldn't be added again is left out of its subscription.
  defp lost(s, ref, key, reason) do
    case s.subscriptions do
      %{^ref => %{targets: %{^key => info}} = subscription} ->
        send(subscription.to, {ADS.Client, ref, {:error, info.target, reason}})
        put_in(s.subscriptions[ref].targets, Map.delete(subscription.targets, key))

      _ ->
        s
    end
  end

  defp orphan(s, port, handle) do
    if MapSet.member?(s.orphans, {port, handle}) or MapSet.size(s.orphans) >= @max_orphans,
      do: s,
      else:
        submit_own(
          %{s | orphans: MapSet.put(s.orphans, {port, handle})},
          port,
          {:delete_notification, handle}
        )
  end

  # A client serves nothing: a request sent to it is answered as one it doesn't support.
  defp refuse(s, packet) do
    if packet.target == s.local and packet.target_port == s.local_ams_port do
      response = %AMS{
        target: packet.source,
        target_port: packet.source_port,
        source: packet.target,
        source_port: packet.target_port,
        command: packet.command,
        state_flags: AMS.response_flags(),
        error_code: @service_not_supported,
        invoke_id: packet.invoke_id
      }

      case send_data(s, AMS.encode(response, s.framing)) do
        :ok -> s
        {:error, reason} -> drop(s, reason)
      end
    else
      s
    end
  end

  defp expire(s, id) do
    case Enum.find(s.pending, fn {_invoke, entry} -> entry.id == id end) do
      {invoke, entry} ->
        reply(entry, {:error, :timeout})
        s = %{s | pending: Map.delete(s.pending, invoke)}

        # Two requests in a row timed out with nothing at all heard since the first went out: the
        # connection is dead, though TCP may not know it yet. One alone may be a slow device, whose
        # late answer then shows it's there.
        cond do
          s.heard >= entry.sent -> flush(s)
          s.silent != nil and s.heard < s.silent -> drop(s, :timeout)
          true -> flush(%{s | silent: entry.sent})
        end

      nil ->
        {expired, kept} = s.queue |> :queue.to_list() |> Enum.split_with(&(&1.id == id))
        Enum.each(expired, &reply(&1, {:error, :timeout}))
        %{s | queue: :queue.from_list(kept)}
    end
  end

  defp unsubscribe(s, ref) do
    case Map.pop(s.subscriptions, ref) do
      {nil, _subscriptions} ->
        s

      {subscription, subscriptions} ->
        Process.demonitor(subscription.monitor, [:flush])

        for {_key, %{handle: handle, port: port}} <- subscription.targets,
            handle != nil,
            reduce: %{s | subscriptions: subscriptions},
            do: (s -> delete_notification(s, port, handle))
    end
  end

  defp delete_notification(s, port, handle) do
    s = %{s | notifications: Map.delete(s.notifications, {port, handle})}
    if s.status == :connected, do: submit_own(s, port, {:delete_notification, handle}), else: s
  end

  # Adds each subscription's notifications again, on a new connection.
  defp resubscribe(s) do
    connection = self()

    for {ref, %{targets: targets}} <- s.subscriptions, map_size(targets) > 0 do
      infos = Map.values(targets)
      spawn(fn -> Enum.each(infos, &ADS.Client.reestablish(connection, ref, &1)) end)
    end

    s
  end

  # Fails everything waiting and connects again after the backoff delay. Handles and notifications
  # go with the connection; subscribers hear of it, and get values again once it's back.
  defp drop(s, reason) do
    _ = if s.socket, do: close(s)

    for {_invoke, entry} <- s.pending, do: fail(entry)
    for entry <- :queue.to_list(s.queue), do: fail(entry)

    {_first, longest} = s.backoff
    Process.send_after(self(), :reconnect, s.delay)

    subscriptions =
      Map.new(s.subscriptions, fn {ref, subscription} ->
        if s.status == :connected,
          do: send(subscription.to, {ADS.Client, ref, {:disconnected, reason}})

        targets =
          Map.new(subscription.targets, fn {key, info} -> {key, %{info | handle: nil}} end)

        {ref, %{subscription | targets: targets}}
      end)

    %{
      s
      | socket: nil,
        silent: nil,
        status: {:disconnected, reason},
        buffer: <<>>,
        pending: %{},
        queue: :queue.new(),
        delay: min(s.delay * 2, longest),
        subscriptions: subscriptions,
        notifications: %{},
        handles: %{},
        types: %{}
    }
  end

  defp fail(entry) do
    _ = Process.cancel_timer(entry.timer)
    reply(entry, {:error, :closed})
  end

  defp reply(%{reply: {:call, from}}, result), do: GenServer.reply(from, result)
  defp reply(%{reply: {:send, to, ref}}, result), do: send(to, {ADS.Client, ref, result})
  defp reply(%{reply: :ignore}, _result), do: :ok

  # On the way out, the device is asked to let go of the notifications and handles, without waiting
  # for its answers; how many requests that took.
  defp let_go(s) do
    deletes =
      for {{port, handle}, _} <- s.notifications, do: {port, {:delete_notification, handle}}

    releases =
      s.handles
      |> Enum.group_by(fn {{port, _name}, _entry} -> port end, fn {_key, entry} ->
        entry.handle
      end)
      |> Enum.flat_map(fn {port, handles} ->
        for chunk <- Enum.chunk_every(handles, ADS.Sum.max()),
            do:
              {port, ADS.Sum.write(for(handle <- chunk, do: {0xF006, 0, <<handle::32-little>>}))}
      end)

    _ =
      Enum.reduce(deletes ++ releases, s.next, fn {port, request}, invoke ->
        {command, data} = Command.encode_request(request)
        entry = %{port: port, command: command, data: data}
        _ = send_data(s, AMS.encode(packet(s, entry, invoke), s.framing))
        if invoke == 0xFFFFFFFF, do: 1, else: invoke + 1
      end)

    length(deletes) + length(releases)
  end

  defp connect(s) do
    client = self()
    config = Map.take(s, [:host, :port, :connect_timeout, :secure, :local_net_id])
    connector = spawn_link(fn -> connector(client, config) end)
    %{s | connector: connector, status: :connecting}
  end

  defp connector(client, config) do
    case open(config) do
      {:ok, socket, info} ->
        owner = if config.secure, do: :ssl, else: :gen_tcp

        case owner.controlling_process(socket, client) do
          :ok -> send(client, {:connected, self(), socket, info})
          {:error, _reason} -> owner.close(socket)
        end

      {:error, reason} ->
        send(client, {:connect_failed, self(), reason})
    end
  end

  defp open(%{secure: nil} = config) do
    case :gen_tcp.connect(config.host, config.port, @options, config.connect_timeout) do
      {:ok, socket} ->
        case local_net_id(socket, config.local_net_id) do
          {:ok, local} ->
            {:ok, socket, %{local: local, remote: nil, buffer: <<>>}}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open(config),
    do:
      Secure.connect(
        config.host,
        config.port,
        config.secure,
        config.local_net_id,
        config.connect_timeout
      )

  # The NetId given, or the address the connection has, with .1.1 added.
  defp local_net_id(_socket, <<_::48>> = local), do: {:ok, local}

  defp local_net_id(socket, nil) do
    case :inet.sockname(socket) do
      {:ok, {{_, _, _, _} = ip, _port}} -> {:ok, NetId.from_ip(ip)}
      _ -> {:error, :local_net_id}
    end
  end

  defp send_data(%{framing: :tcp, socket: socket}, data), do: :gen_tcp.send(socket, data)
  defp send_data(%{framing: :tls, socket: socket}, data), do: :ssl.send(socket, data)

  defp setopts(%{framing: :tcp, socket: socket}, opts), do: :inet.setopts(socket, opts)
  defp setopts(%{framing: :tls, socket: socket}, opts), do: :ssl.setopts(socket, opts)

  defp shutdown(%{framing: :tcp, socket: socket}), do: :gen_tcp.shutdown(socket, :write)
  defp shutdown(%{framing: :tls, socket: socket}), do: :ssl.shutdown(socket, :write)

  defp close(%{framing: :tcp, socket: socket}), do: :gen_tcp.close(socket)
  defp close(%{framing: :tls, socket: socket}), do: :ssl.close(socket)

  defp now, do: System.monotonic_time()
end
