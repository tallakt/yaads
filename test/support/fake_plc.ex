defmodule ADS.Test.FakePLC do
  @moduledoc false
  # A TwinCAT PLC as far as the tests need one: a router on a TCP port, or on TLS as Secure ADS has
  # it, with a device on AMS port 851 that keeps some variables in its data area (index group
  # 0x4040), describes them as symbols and data types, gives handles of their names, does sum
  # commands, and sends notifications. Played from the spec, as the client reads it; a real PLC
  # is the test of both.
  #
  # With routes:, a list of NetIds, it closes a connection whose packets come from any other, as
  # TwinCAT does without a route; add_route/2 adds one. It keeps what each connection held when it
  # closed, its handles and notifications, in leftovers/1, by the connection's process: none, for a
  # client that let go of them.
  #
  # With system: true, AMS port 10000 is TwinCAT's system service, in run, as far as its state.
  # port: and ip: are where it listens, for a router that connects to it as to a PLC.
  use GenServer

  alias ADS.{AMS, Command, Type}

  @net_id <<5, 36, 69, 176, 1, 1>>
  @data 0x4040
  @memory 0x4020

  @mode {:enum, :int, [{"eOff", 0}, {"eAuto", 1}, {"eManual", 2}]}
  @pump Type.layout([
          {"nSpeed", :int},
          {"fTemp", :lreal},
          {"bRunning", :bool},
          {"eMode", @mode},
          {"sTag", {:string, 10}}
        ])
  @flags {:struct, 2, [{"bA", 0, :bit}, {"bB", 1, :bit}, {"nRest", 1, :byte}]}

  # name, type name, type, data type id, attributes
  @variables [
    {"MAIN.nCounter", "DINT", :dint, 3, %{}},
    {"MAIN.nSpeed", "INT", :int, 2, %{}},
    {"MAIN.bOn", "BOOL", :bool, 33, %{}},
    {"MAIN.fTemp", "LREAL", :lreal, 5, %{}},
    {"MAIN.sName", "STRING(20)", {:string, 20}, 30, %{}},
    {"MAIN.wsText", "WSTRING(10)", {:wstring, 10}, 31, %{}},
    {"MAIN.aValues", "ARRAY [1..5] OF INT", {:array, :int, [{1, 5}]}, 2, %{}},
    {"MAIN.stPump", "ST_Pump", @pump, 65, %{}},
    {"MAIN.aPumps", "ARRAY [0..1] OF ST_Pump", {:array, @pump, [{0, 1}]}, 65, %{}},
    {"MAIN.eMode", "E_Mode", @mode, 2, %{}},
    {"MAIN.tDelay", "TIME", :time, 19, %{}},
    {"MAIN.dtStamp", "DATE_AND_TIME", :date_and_time, 19, %{}},
    {"MAIN.sText", "T_MaxString", {:string, 255}, 30, %{}},
    {"MAIN.stFlags", "ST_Flags", @flags, 65, %{}},
    {"GVL.sUtf8", "STRING(20)", {:string, 20, :utf8}, 30, %{"TcEncoding" => "UTF-8"}}
  ]

  def net_id, do: @net_id
  def variables, do: @variables
  def pump, do: @pump
  def mode, do: @mode
  def flags, do: @flags

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def port(plc), do: GenServer.call(plc, :port)
  def get(plc, name), do: GenServer.call(plc, {:get, name})
  def put(plc, name, value), do: GenServer.call(plc, {:put, name, value})
  def requests(plc), do: GenServer.call(plc, :requests)
  def handles(plc), do: GenServer.call(plc, :handles)
  def notifications(plc), do: GenServer.call(plc, :notifications)
  def connect_infos(plc), do: GenServer.call(plc, :connect_infos)
  def online_change(plc), do: GenServer.call(plc, :online_change)
  def drop_connections(plc), do: GenServer.call(plc, :drop_connections)
  def set(plc, key, value), do: GenServer.call(plc, {:set, key, value})
  def add_route(plc, net_id), do: GenServer.call(plc, {:add_route, net_id})
  def delete_route(plc, net_id), do: GenServer.call(plc, {:delete_route, net_id})
  def leftovers(plc), do: GenServer.call(plc, :leftovers)
  def connections(plc), do: GenServer.call(plc, :connections)

  @impl true
  def init(opts) do
    secure = Keyword.get(opts, :secure)

    {:ok, listen} =
      if secure,
        do:
          :ssl.listen(
            0,
            [:binary, active: false, reuseaddr: true, log_level: :none] ++ secure.ssl
          ),
        else:
          :gen_tcp.listen(
            Keyword.get(opts, :port, 0),
            [:binary, active: false, reuseaddr: true] ++ Keyword.take(opts, [:ip])
          )

    {:ok, {_, port}} = if secure, do: :ssl.sockname(listen), else: :inet.sockname(listen)
    plc = self()
    spawn_link(fn -> accept(plc, listen, secure) end)

    {offsets, size} =
      Enum.map_reduce(@variables, 0, fn {name, _, type, _, _}, at ->
        at = round_up(at, 8)
        {{String.downcase(name), at}, at + Type.size(type)}
      end)

    {:ok,
     %{
       port: port,
       secure: secure,
       data: :binary.copy(<<0>>, size),
       memory: :binary.copy(<<0>>, 1024),
       offsets: Map.new(offsets),
       handles: %{},
       next_handle: 100,
       notifications: %{},
       next_notification: 1,
       version: 1,
       ads_state: 5,
       requests: [],
       connections: [],
       connect_infos: [],
       routes: Keyword.get(opts, :routes),
       leftovers: [],
       caller: nil,
       # A type name whose description, asked for, isn't answered, once.
       mute: nil,
       sum: Keyword.get(opts, :sum, true),
       system: Keyword.get(opts, :system, false),
       # With system:, the routes its system service lists, each %{name, net_id, address, flags}.
       route_entries: Keyword.get(opts, :route_entries, []),
       silent: false
     }}
  end

  defp round_up(n, a), do: div(n + a - 1, a) * a

  defp accept(plc, listen, secure) do
    case accept_one(listen, secure) do
      {:ok, socket} ->
        {:ok, pid} = ADS.Test.FakePLC.Connection.start(plc, socket, secure)

        _ =
          if secure,
            do: :ssl.controlling_process(socket, pid),
            else: :gen_tcp.controlling_process(socket, pid)

        send(pid, :go)
        accept(plc, listen, secure)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept(plc, listen, secure)
    end
  end

  defp accept_one(listen, nil), do: :gen_tcp.accept(listen)

  defp accept_one(listen, _secure) do
    with {:ok, socket} <- :ssl.transport_accept(listen), do: :ssl.handshake(socket, 5000)
  end

  @impl true
  def handle_call(:port, _from, s), do: {:reply, s.port, s}

  def handle_call({:get, name}, _from, s) do
    {offset, type} = variable!(s, name)
    {:ok, value} = Type.decode(type, binary_part(s.data, offset, Type.size(type)))
    {:reply, value, s}
  end

  def handle_call({:put, name, value}, _from, s) do
    {offset, type} = variable!(s, name)
    {:reply, :ok, write_area(s, @data, offset, Type.encode(type, value))}
  end

  def handle_call(:requests, _from, s), do: {:reply, Enum.reverse(s.requests), s}
  def handle_call(:handles, _from, s), do: {:reply, map_size(s.handles), s}
  def handle_call(:notifications, _from, s), do: {:reply, map_size(s.notifications), s}
  def handle_call(:connect_infos, _from, s), do: {:reply, Enum.reverse(s.connect_infos), s}
  def handle_call({:set, key, value}, _from, s), do: {:reply, :ok, Map.put(s, key, value)}
  def handle_call(:leftovers, _from, s), do: {:reply, Enum.reverse(s.leftovers), s}
  def handle_call(:connections, _from, s), do: {:reply, s.connections, s}

  def handle_call({:add_route, net_id}, _from, s),
    do: {:reply, :ok, %{s | routes: [ADS.NetId.parse!(net_id) | s.routes || []]}}

  def handle_call({:delete_route, net_id}, _from, s),
    do: {:reply, :ok, %{s | routes: List.delete(s.routes || [], ADS.NetId.parse!(net_id))}}

  # As after a download: every handle is gone, and each notification on one says so, once.
  def handle_call(:online_change, _from, s) do
    for {handle, %{group: 0xF005} = n} <- s.notifications,
        do: notify(n, [{handle, <<>>}])

    notifications = Map.reject(s.notifications, fn {_handle, n} -> n.group == 0xF005 end)
    {:reply, :ok, %{s | handles: %{}, notifications: notifications, version: s.version + 1}}
  end

  def handle_call(:drop_connections, _from, s) do
    for pid <- s.connections, do: Process.exit(pid, :kill)
    {:reply, :ok, %{s | connections: []}}
  end

  def handle_call({:connected, pid}, _from, s) do
    Process.monitor(pid)
    {:reply, :ok, %{s | connections: [pid | s.connections]}}
  end

  def handle_call({:connect_info, info}, _from, s) do
    s = %{s | connect_infos: [info | s.connect_infos]}

    answer =
      if :add_remote in info.flags and info.credentials != {"Administrator", "1"}, do: 4, else: 0

    {:reply, answer, s}
  end

  def handle_call({:packet, pid, packet}, _from, s) do
    s = %{s | requests: [{packet.command, packet.data} | s.requests]}

    cond do
      unrouted?(s, packet) ->
        {:reply, :close, s}

      quiet?(s, packet) ->
        {:reply, :none, %{s | mute: nil}}

      packet.target != @net_id ->
        {:reply, {:error_code, 0x7}, s}

      s.system and packet.target_port == 10_000 ->
        {:reply, system(s, packet), s}

      packet.target_port != 851 ->
        {:reply, {:error_code, 0x6}, s}

      true ->
        {result, s} = command(s, pid, packet)
        {:reply, result, s}
    end
  end

  defp unrouted?(s, packet), do: s.routes != nil and packet.source not in s.routes
  defp quiet?(s, packet), do: s.silent or muted?(s, packet)

  defp muted?(%{mute: nil}, _packet), do: false

  defp muted?(s, %{command: 9, data: <<0xF011::32-little, _::64, _::32, name::binary>>}),
    do: name |> :binary.split(<<0>>) |> hd() == s.mute

  defp muted?(_s, _packet), do: false

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, s) do
    {gone, notifications} = Map.split_with(s.notifications, fn {_handle, n} -> n.pid == pid end)

    held = %{
      handles: Enum.count(s.handles, fn {_, v} -> v.owner == pid end),
      notifications: map_size(gone)
    }

    {:noreply,
     %{
       s
       | connections: List.delete(s.connections, pid),
         notifications: notifications,
         leftovers: [{pid, held} | s.leftovers]
     }}
  end

  def handle_info({:cycle, handle}, s) do
    case s.notifications do
      %{^handle => n} ->
        notify(n, [{handle, read_region(s, n)}])
        Process.send_after(self(), {:cycle, handle}, n.interval)

      _ ->
        :ok
    end

    {:noreply, s}
  end

  defp variable!(s, name) do
    {_, _, type, _, _} =
      Enum.find(@variables, fn {n, _, _, _, _} -> String.downcase(n) == String.downcase(name) end)

    {Map.fetch!(s.offsets, String.downcase(name)), type}
  end

  defp variable(s, name) do
    name = name |> :binary.split(<<0>>) |> hd()

    case Enum.find(@variables, fn {n, _, _, _, _} ->
           String.downcase(n) == String.downcase(name)
         end) do
      nil ->
        nil

      {n, type_name, type, id, attributes} ->
        %{
          name: n,
          type_name: type_name,
          type: type,
          id: id,
          attributes: attributes,
          offset: s.offsets[String.downcase(n)]
        }
    end
  end

  defp system(_s, %{command: 4}), do: {:ok, <<0::32, 5::16-little, 0::16>>}

  # Its routes, by index, as TwinCAT 3.1 4026 lists them, and 0x716 after the last.
  defp system(s, %{command: 2, data: <<803::32-little, index::32-little, _length::32-little>>}) do
    case Enum.at(s.route_entries, index) do
      nil ->
        {:ok, <<0x716::32-little, 0::32>>}

      route ->
        entry = route_entry(route)
        {:ok, <<0::32, byte_size(entry)::32-little, entry::binary>>}
    end
  end

  defp system(_s, _packet), do: {:ok, <<0x701::32-little>>}

  def route_entry(route) do
    address = route.address <> <<0>>
    name = route.name <> <<0>>

    <<ADS.NetId.parse!(route.net_id)::binary, 1::16-little, Map.get(route, :flags, 0)::32-little,
      60_000::32-little, 0::128, byte_size(address)::32-little, byte_size(name)::32-little, 0::32,
      address::binary, name::binary>>
  end

  # The commands, each giving the data of its response, and the device as it is after.
  defp command(s, _pid, %{command: 1}),
    do: {{:ok, <<0::32, 3, 1, 4026::16-little, pad("Plc30 App", 16)::binary>>}, s}

  defp command(s, _pid, %{command: 4}), do: {{:ok, <<0::32, s.ads_state::16-little, 0::16>>}, s}

  defp command(s, _pid, %{
         command: 5,
         data: <<state::16-little, _device::16-little, _rest::binary>>
       }),
       do: {{:ok, <<0::32>>}, %{s | ads_state: state}}

  defp command(s, _pid, %{
         command: 2,
         data: <<group::32-little, offset::32-little, length::32-little>>
       }) do
    case read(s, group, offset, length) do
      {:ok, data} -> {{:ok, <<0::32, byte_size(data)::32-little, data::binary>>}, s}
      {:error, code} -> {{:ok, <<code::32-little, 0::32>>}, s}
    end
  end

  defp command(s, _pid, %{
         command: 3,
         data:
           <<group::32-little, offset::32-little, length::32-little, data::binary-size(length)>>
       }) do
    case write(s, group, offset, data) do
      {:ok, s} -> {{:ok, <<0::32>>}, s}
      {:error, code} -> {{:ok, <<code::32-little>>}, s}
    end
  end

  defp command(s, pid, %{
         command: 9,
         data:
           <<group::32-little, offset::32-little, read_length::32-little, length::32-little,
             data::binary-size(length)>>
       }) do
    case read_write(Map.put(s, :caller, pid), group, offset, read_length, data) do
      {:ok, out, s} -> {{:ok, <<0::32, byte_size(out)::32-little, out::binary>>}, s}
      {:error, code, s} -> {{:ok, <<code::32-little, 0::32>>}, s}
    end
  end

  # Beckhoff's own client leaves out the 16 reserved bytes at the end.
  defp command(s, pid, %{command: 6} = packet) do
    <<group::32-little, offset::32-little, length::32-little, mode::32-little, _delay::32-little,
      cycle::32-little, _reserved::binary>> = packet.data

    cond do
      mode not in [3, 4] ->
        {{:ok, <<0x713::32-little, 0::32>>}, s}

      match?({:error, _}, read(s, group, offset, length)) ->
        {:error, code} = read(s, group, offset, length)
        {{:ok, <<code::32-little, 0::32>>}, s}

      true ->
        handle = s.next_notification

        n = %{
          pid: pid,
          client: {packet.source, packet.source_port},
          group: group,
          offset: offset,
          length: length,
          mode: mode,
          interval: max(div(cycle, 10_000), 10),
          last: nil
        }

        n = %{n | last: read_region(s, n)}
        if mode == 3, do: Process.send_after(self(), {:cycle, handle}, n.interval)
        # The value as it is, at once, after the answer.
        notify_later(n, handle, n.last)

        {{:ok, <<0::32, handle::32-little>>},
         %{s | notifications: Map.put(s.notifications, handle, n), next_notification: handle + 1}}
    end
  end

  defp command(s, _pid, %{command: 7, data: <<handle::32-little>>}) do
    if Map.has_key?(s.notifications, handle),
      do: {{:ok, <<0::32>>}, %{s | notifications: Map.delete(s.notifications, handle)}},
      else: {{:ok, <<0x714::32-little>>}, s}
  end

  defp command(s, _pid, %{command: command}) when command in 1..9,
    do: {{:ok, <<0x705::32-little>>}, s}

  defp command(s, _pid, _packet), do: {{:error_code, 0x8}, s}

  defp notify_later(n, handle, data),
    do: send(n.pid, {:notify_after_answer, n.client, [{handle, data}]})

  defp notify(n, samples), do: send(n.pid, {:notify, n.client, samples})

  defp read(s, @data, offset, length), do: slice(s.data, offset, length)
  defp read(s, @memory, offset, length), do: slice(s.memory, offset, length)

  defp read(s, 0xF005, handle, length) do
    case s.handles do
      %{^handle => v} ->
        if length == Type.size(v.type), do: slice(s.data, v.offset, length), else: {:error, 0x705}

      _ ->
        {:error, 0x710}
    end
  end

  defp read(s, 0xF008, 0, length) when length >= 1, do: {:ok, <<s.version>>}

  # The device's data: its ADS state and device state, as read state has them.
  defp read(s, 0xF100, 0, length) when length in 1..4,
    do: {:ok, binary_part(<<s.ads_state::16-little, 0::16>>, 0, length)}

  defp read(_s, 0xF00F, 0, length) when length >= 24 do
    symbols = symbol_upload()
    types = type_upload()

    {:ok,
     <<length(@variables)::32-little, byte_size(symbols)::32-little,
       length(type_entries())::32-little, byte_size(types)::32-little, 0::32, 0::32>>}
  end

  defp read(_s, 0xF00C, 0, length) when length >= 8,
    do: {:ok, <<length(@variables)::32-little, byte_size(symbol_upload())::32-little>>}

  defp read(_s, 0xF00B, 0, length) do
    upload = symbol_upload()
    if length >= byte_size(upload), do: {:ok, upload}, else: {:error, 0x705}
  end

  defp read(_s, 0xF00E, 0, length) do
    upload = type_upload()
    if length >= byte_size(upload), do: {:ok, upload}, else: {:error, 0x705}
  end

  defp read(_s, _group, _offset, _length), do: {:error, 0x702}

  defp slice(area, offset, length) do
    if offset + length <= byte_size(area),
      do: {:ok, binary_part(area, offset, length)},
      else: {:error, 0x703}
  end

  defp write(s, group, offset, data) when group in [@data, @memory] do
    area = if group == @data, do: s.data, else: s.memory

    if offset + byte_size(data) <= byte_size(area),
      do: {:ok, write_area(s, group, offset, data)},
      else: {:error, 0x703}
  end

  defp write(s, 0xF005, handle, data) do
    case s.handles do
      %{^handle => v} ->
        if byte_size(data) == Type.size(v.type),
          do: {:ok, write_area(s, @data, v.offset, data)},
          else: {:error, 0x705}

      _ ->
        {:error, 0x710}
    end
  end

  defp write(s, 0xF006, 0, <<handle::32-little>>) do
    if Map.has_key?(s.handles, handle),
      do: {:ok, %{s | handles: Map.delete(s.handles, handle)}},
      else: {:error, 0x710}
  end

  defp write(_s, _group, _offset, _data), do: {:error, 0x702}

  # Writes to an area, and sends the notifications on change whose values it changed.
  defp write_area(s, group, offset, data) do
    s =
      case group do
        @data -> %{s | data: replace(s.data, offset, data)}
        @memory -> %{s | memory: replace(s.memory, offset, data)}
      end

    notifications =
      Map.new(s.notifications, fn {handle, n} ->
        value = read_region(s, n)

        if n.mode == 4 and value != n.last do
          notify(n, [{handle, value}])
          {handle, %{n | last: value}}
        else
          {handle, n}
        end
      end)

    %{s | notifications: notifications}
  end

  defp replace(area, offset, data) do
    <<before::binary-size(offset), _::binary-size(byte_size(data)), rest::binary>> = area
    <<before::binary, data::binary, rest::binary>>
  end

  defp read_region(s, %{group: 0xF005, offset: handle, length: length}) do
    case s.handles do
      %{^handle => v} -> binary_part(s.data, v.offset, length)
      _ -> <<>>
    end
  end

  defp read_region(s, %{group: group, offset: offset, length: length}) do
    {:ok, data} = read(s, group, offset, length)
    data
  end

  # A handle is the connection's that asked for it, s.caller.
  defp read_write(s, 0xF003, 0, 4, name) do
    case variable(s, name) do
      nil ->
        {:error, 0x710, s}

      v ->
        v = Map.put(v, :owner, s.caller)

        {:ok, <<s.next_handle::32-little>>,
         %{s | handles: Map.put(s.handles, s.next_handle, v), next_handle: s.next_handle + 1}}
    end
  end

  defp read_write(s, 0xF009, 0, read_length, name) do
    case variable(s, name) do
      nil ->
        {:error, 0x710, s}

      v ->
        entry = symbol_entry(v)
        if byte_size(entry) <= read_length, do: {:ok, entry, s}, else: {:error, 0x705, s}
    end
  end

  defp read_write(s, 0xF011, 0, read_length, name) do
    name = name |> :binary.split(<<0>>) |> hd() |> String.downcase()

    case Enum.find(type_entries(), fn {type_name, _entry} ->
           String.downcase(type_name) == name
         end) do
      {_name, entry} ->
        if byte_size(entry) <= read_length, do: {:ok, entry, s}, else: {:error, 0x705, s}

      nil ->
        {:error, 0x710, s}
    end
  end

  defp read_write(%{sum: false} = s, group, _offset, _length, _data) when group in 0xF080..0xF082,
    do: {:error, 0x701, s}

  defp read_write(s, 0xF080, n, _length, data) do
    reads =
      for <<group::32-little, offset::32-little,
            length::32-little <- binary_part(data, 0, 12 * n)>>,
          do: {group, offset, length}

    results = for {group, offset, length} <- reads, do: {length, read(s, group, offset, length)}
    codes = for {_, result} <- results, into: <<>>, do: <<code(result)::32-little>>

    out =
      for {length, result} <- results,
          into: <<>>,
          do:
            (case result do
               {:ok, d} -> d
               _ -> :binary.copy(<<0>>, length)
             end)

    {:ok, codes <> out, s}
  end

  defp read_write(s, 0xF081, n, _length, data) do
    <<headers::binary-size(12 * n), rest::binary>> = data

    writes =
      for <<group::32-little, offset::32-little, length::32-little <- headers>>,
        do: {group, offset, length}

    {codes, {s, _rest}} =
      Enum.map_reduce(writes, {s, rest}, fn {group, offset, length}, {s, rest} ->
        <<part::binary-size(length), rest::binary>> = rest

        case write(s, group, offset, part) do
          {:ok, s} -> {<<0::32>>, {s, rest}}
          {:error, code} -> {<<code::32-little>>, {s, rest}}
        end
      end)

    {:ok, IO.iodata_to_binary(codes), s}
  end

  defp read_write(s, 0xF082, n, _length, data) do
    <<headers::binary-size(16 * n), rest::binary>> = data

    items =
      for <<g::32-little, o::32-little, r::32-little, w::32-little <- headers>>, do: {g, o, r, w}

    {results, {s, _rest}} =
      Enum.map_reduce(items, {s, rest}, fn {group, offset, read_length, length}, {s, rest} ->
        <<part::binary-size(length), rest::binary>> = rest

        case read_write(s, group, offset, read_length, part) do
          {:ok, out, s} -> {{0, out}, {s, rest}}
          {:error, code, s} -> {{code, <<>>}, {s, rest}}
        end
      end)

    heads =
      for {code, out} <- results, into: <<>>, do: <<code::32-little, byte_size(out)::32-little>>

    {:ok, heads <> IO.iodata_to_binary(for {_, out} <- results, do: out), s}
  end

  defp read_write(s, _group, _offset, _length, _data), do: {:error, 0x702, s}

  defp code({:ok, _}), do: 0
  defp code({:error, code}), do: code

  defp pad(string, n), do: string <> :binary.copy(<<0>>, n - byte_size(string))

  # Symbol and data type entries as the client reads them, padded to 8 bytes as a PLC may.
  def symbol_entry(v) do
    attributes = attributes_part(v.attributes)
    flags = if v.attributes == %{}, do: 0x0008, else: 0x1008
    comment = "the #{v.name}"

    body =
      <<@data::32-little, v.offset::32-little, Type.size(v.type)::32-little, v.id::32-little,
        flags::32-little, byte_size(v.name)::16-little, byte_size(v.type_name)::16-little,
        byte_size(comment)::16-little, v.name::binary, 0, v.type_name::binary, 0, comment::binary,
        0, 0x12345678::32-little, 0x9ABC::16-little, 0xDEF0::16-little, 1, 2, 3, 4, 5, 6, 7, 8,
        attributes::binary>>

    entry(body)
  end

  defp entry(body) do
    length = round_up(4 + byte_size(body), 8)
    <<length::32-little, body::binary, 0::size((length - 4 - byte_size(body)) * 8)>>
  end

  defp attributes_part(attributes) when attributes == %{}, do: <<>>

  defp attributes_part(attributes) do
    for {name, value} <- attributes,
        into: <<map_size(attributes)::16-little>>,
        do: <<byte_size(name), byte_size(value), name::binary, 0, value::binary, 0>>
  end

  def symbol_upload do
    s = %{offsets: offsets()}
    for {name, _, _, _, _} <- @variables, into: <<>>, do: symbol_entry(variable(s, name))
  end

  defp offsets do
    {offsets, _} =
      Enum.map_reduce(@variables, 0, fn {name, _, type, _, _}, at ->
        at = round_up(at, 8)
        {{String.downcase(name), at}, at + Type.size(type)}
      end)

    Map.new(offsets)
  end

  def type_upload, do: for({_name, entry} <- type_entries(), into: <<>>, do: entry)

  # Each flagged a data type (0x1), as TwinCAT 3's are, which ads-client goes by; the array of a
  # symbol has one too, as ads-client asks for it.
  def type_entries do
    {:struct, pump_size, members} = @pump

    member_types = %{
      "nSpeed" => {"INT", 2},
      "fTemp" => {"LREAL", 5},
      "bRunning" => {"BOOL", 33},
      "eMode" => {"E_Mode", 2},
      "sTag" => {"STRING(10)", 30}
    }

    pump =
      type_entry("ST_Pump", "", pump_size, 0, 65, 0x1,
        members:
          for {name, offset, type} <- members do
            {type_name, id} = member_types[name]
            type_entry(name, type_name, Type.size(type), offset, id, 0x2)
          end
      )

    mode =
      type_entry("E_Mode", "INT", 2, 0, 2, 0x2001,
        enum: [{"eOff", 0}, {"eAuto", 1}, {"eManual", 2}]
      )

    max_string = type_entry("T_MaxString", "STRING(255)", 256, 0, 30, 0x1)
    values = type_entry("ARRAY [1..5] OF INT", "INT", 10, 0, 2, 0x1, array: [{1, 5}])

    pumps =
      type_entry("ARRAY [0..1] OF ST_Pump", "ST_Pump", 2 * pump_size, 0, 65, 0x1, array: [{0, 2}])

    flags =
      type_entry("ST_Flags", "", 2, 0, 65, 0x1,
        members: [
          type_entry("bA", "BIT", 1, 0, 33, 0x22),
          type_entry("bB", "BIT", 1, 1, 33, 0x22),
          type_entry("nRest", "BYTE", 1, 1, 17, 0x2)
        ]
      )

    [
      {"ST_Pump", pump},
      {"E_Mode", mode},
      {"T_MaxString", max_string},
      {"ARRAY [1..5] OF INT", values},
      {"ARRAY [0..1] OF ST_Pump", pumps},
      {"ST_Flags", flags}
    ]
  end

  def type_entry(name, type, size, offset, id, flags, opts \\ []) do
    array = Keyword.get(opts, :array, [])
    members = Keyword.get(opts, :members, [])
    enum = Keyword.get(opts, :enum, [])

    enum_part =
      if enum == [],
        do: <<>>,
        else:
          for(
            {n, v} <- enum,
            into: <<length(enum)::16-little>>,
            do: <<byte_size(n), n::binary, 0, v::little-size(size * 8)>>
          )

    body =
      <<1::32-little, 0::32, 0::32, size::32-little, offset::32-little, id::32-little,
        flags::32-little, byte_size(name)::16-little, byte_size(type)::16-little, 0::16,
        length(array)::16-little, length(members)::16-little, name::binary, 0, type::binary, 0,
        0>> <>
        for({first, n} <- array, into: <<>>, do: <<first::signed-32-little, n::32-little>>) <>
        IO.iodata_to_binary(members) <> enum_part

    entry(body)
  end
end

defmodule ADS.Test.FakePLC.Connection do
  @moduledoc false
  # A connection to the fake PLC: AMS packets in, each handed to the PLC, and its answers and
  # notifications out; on TLS, after a TlsConnectInfo each way.
  alias ADS.{AMS, Command, Secure}

  def start(plc, socket, secure), do: {:ok, spawn(fn -> init(plc, socket, secure) end)}

  defp init(plc, socket, secure) do
    receive do
      :go -> :ok
    end

    :ok = GenServer.call(plc, {:connected, self()})

    s = %{
      plc: plc,
      socket: socket,
      secure: secure,
      framing: if(secure, do: :tls, else: :tcp),
      buffer: <<>>
    }

    if secure do
      case connect_info(s, <<>>) do
        {:ok, rest} -> loop(%{s | buffer: rest})
        :error -> :ssl.close(socket)
      end
    else
      loop(s)
    end
  end

  defp connect_info(s, buffer) do
    case Secure.decode_connect_info(buffer) do
      {:ok, info, rest} ->
        error = GenServer.call(s.plc, {:connect_info, info})

        answer =
          Secure.connect_info([:response, :ams_allowed], ADS.Test.FakePLC.net_id(), "fake-plc")

        <<head::binary-5, _error, tail::binary>> = answer
        :ok = :ssl.send(s.socket, <<head::binary, error, tail::binary>>)
        if error == 0, do: {:ok, rest}, else: :error

      :more ->
        case :ssl.recv(s.socket, 0, 5000) do
          {:ok, data} -> connect_info(s, buffer <> data)
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp loop(s) do
    case AMS.decode(s.buffer, s.framing) do
      {:ok, packet, rest} ->
        case answer(s, packet) do
          :close -> close(s)
          :ok -> loop(%{s | buffer: rest})
        end

      {:discard, rest} ->
        loop(%{s | buffer: rest})

      :more ->
        setopts(s, active: :once)
        receive_more(s)

      {:error, _} ->
        close(s)
    end
  end

  defp receive_more(s) do
    receive do
      {protocol, _socket, data} when protocol in [:tcp, :ssl] ->
        loop(%{s | buffer: s.buffer <> data})

      {closed, _socket} when closed in [:tcp_closed, :ssl_closed] ->
        :ok

      {:notify, client, samples} ->
        notify(s, client, samples)
        receive_more(s)

      {:notify_after_answer, client, samples} ->
        notify(s, client, samples)
        receive_more(s)

      _other ->
        receive_more(s)
    end
  end

  defp answer(s, packet) do
    result =
      if AMS.response?(packet), do: :none, else: GenServer.call(s.plc, {:packet, self(), packet})

    case result do
      {:ok, data} -> send_packet(s, response(packet, 0, data))
      {:error_code, code} -> send_packet(s, response(packet, code, <<>>))
      _none_or_close -> :ok
    end

    # Notifications the answer led to go after it.
    flush_notifications(s)
    if result == :close, do: :close, else: :ok
  end

  defp flush_notifications(s) do
    receive do
      {:notify_after_answer, client, samples} ->
        notify(s, client, samples)
        flush_notifications(s)
    after
      0 -> :ok
    end
  end

  defp response(packet, code, data) do
    %AMS{
      target: packet.source,
      target_port: packet.source_port,
      source: packet.target,
      source_port: packet.target_port,
      command: packet.command,
      state_flags: AMS.response_flags(),
      error_code: code,
      invoke_id: packet.invoke_id,
      data: data
    }
  end

  defp notify(s, {net_id, port}, samples) do
    packet = %AMS{
      target: net_id,
      target_port: port,
      source: ADS.Test.FakePLC.net_id(),
      source_port: 851,
      command: 8,
      data: Command.encode_notification([{DateTime.utc_now(), samples}])
    }

    send_packet(s, packet)
  end

  defp send_packet(s, packet) do
    data = AMS.encode(packet, s.framing)
    _ = if s.secure, do: :ssl.send(s.socket, data), else: :gen_tcp.send(s.socket, data)
  end

  defp setopts(%{secure: nil, socket: socket}, opts), do: :inet.setopts(socket, opts)
  defp setopts(%{socket: socket}, opts), do: :ssl.setopts(socket, opts)

  defp close(%{secure: nil, socket: socket}), do: :gen_tcp.close(socket)
  defp close(%{socket: socket}), do: :ssl.close(socket)
end
