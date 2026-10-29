defmodule ADS.Client do
  @moduledoc """
  A connection to an ADS device, usually a TwinCAT PLC, over TCP or Secure ADS.

      {:ok, plc} = ADS.Client.start_link(host: "10.0.0.5", net_id: "5.36.69.176.1.1")

      {:ok, 1500} = ADS.Client.read(plc, "MAIN.nSpeed")
      :ok = ADS.Client.write(plc, "MAIN.nSpeed", 1600)
      {:ok, %{"nSpeed" => 1600, "fTemp" => 21.5}} = ADS.Client.read(plc, "MAIN.stPump")
      {:ok, [{:ok, 1600}, {:ok, true}]} = ADS.Client.read_many(plc, ["MAIN.nSpeed", "MAIN.bOn"])

      {:error, :device_symbol_not_found} = ADS.Client.read(plc, "MAIN.nNone")

  The client talks to one system, by its AMS NetId, and to the PLC runtime on AMS port 851 unless
  told otherwise: `ams_port:` for the client, or `port:` for one request. Every request gets its
  result within its timeout, as a value: the client never exits the caller, and it never logs.
  The errors are those listed in `ADS`.

  ## Routes

  A TwinCAT system talks only to clients it has a route for: the client's NetId and its address,
  added in TwinCAT's engineering, its system tray menu or a target's web interface. The client's
  NetId is `:local_net_id`, by default its IP address on the connection with `.1.1` added. To a
  client without a route, the system closes the connection, and the client tries again. So it does
  to a second connection from a NetId it's already connected to: clients on one machine to the
  same system share one client, or each has a NetId and a route of its own.

  ## Variables by name

  `read/3` and `write/4` reach a variable by its name, as the PLC knows it, `"MAIN.nSpeed"` or
  `"GVL.astPumps[2].fTemp"`. The client asks the PLC for a handle of the name, and for the
  descriptions of its type (see `ADS.Symbol` and `ADS.DataType`), and keeps both for as long as
  the connection lasts. Values are Elixir terms as in `ADS.Type`: a structure is a map, an array a
  list. A handle that has gone stale, as after an online change, is looked up again, once.

  `type:` gives the type instead, which saves asking for its description, and also reaches data by
  index group and offset:

      {:ok, 1500} = ADS.Client.read(plc, "MAIN.nSpeed", type: :int)
      {:ok, 42} = ADS.Client.read(plc, {0x4020, 0}, type: :dint)
      :ok = ADS.Client.write(plc, {0x4020, 4}, [1, 2, 3], type: {:array, :int, [{1, 3}]})

  `read_many/3` and `write_many/3` read and write many at once, in sum commands of up to 500, or
  one at a time with a device that has none. `symbols/2` and `data_types/2` upload all of the
  PLC's descriptions, and `request/3` sends any ADS command (see `ADS.Command`).

  ## Notifications

  `subscribe/3` asks the PLC to send a variable's value when it changes, or every cycle, to the
  subscriber, the caller by default:

      {:ok, ref} = ADS.Client.subscribe(plc, ["MAIN.nSpeed", "MAIN.bOn"], cycle_time: 100)

      # the current values at once, then each change
      receive do
        {ADS.Client, ^ref, {:value, "MAIN.nSpeed", speed, %DateTime{}}} -> speed
      end

  | Message | When |
  |---|---|
  | `{ADS.Client, ref, {:value, target, value, timestamp}}` | a value, with the PLC's time of it in UTC |
  | `{ADS.Client, ref, {:disconnected, reason}}` | the connection dropped; the values come again once it's back |
  | `{ADS.Client, ref, {:error, target, reason}}` | a notification couldn't be added again, after a reconnect or an online change; the target is left out |

  A subscription ends with `unsubscribe/2`, or when the subscriber exits. Beckhoff recommends at
  most 550 notifications for a device.

  ## Many requests at once

  Up to `:max_pending` requests are on the way at once, matched to their answers by invoke id;
  more wait in the client, within their own timeouts. Callers may share a client, and
  `send_request/3` lets one process have many requests out.

  ## Connections

  `start_link/1` returns at once, and the client connects in the background: a request made while
  it's connecting waits for the connection. When the connection drops, the client connects again
  by itself, after 100 ms at first and up to 5 seconds between attempts (`:backoff`), and adds its
  subscriptions' notifications again. While it's down, requests fail at once with
  `{:error, :closed}`, and `status/1` says why. Two requests in a row that time out with nothing at
  all heard since the first was sent mean the connection is dead, and the client reconnects.

  ## Secure ADS

  `secure:` connects to port 8016 with TLS 1.2, as `ADS.Secure` describes, in one of three ways:

      # a pre-shared key, as in the PLC's StaticRoutes.xml
      secure: [psk: {"scada", "secret"}]

      # certificates from a CA both sides trust
      secure: [cacertfile: "ca.pem", certfile: "scada.crt", keyfile: "scada.key"]

      # self-signed: the PLC's certificate known by its fingerprint, and a route added once
      secure: [fingerprint: "6E:3B:...", certfile: "scada.pem", keyfile: "scada.key",
               add_route: {"Administrator", "1"}]

  The PLC's NetId comes in its answer, so `net_id:` may be left out.

  | Option | |
  |---|---|
  | `:psk` | `{identity, password}` |
  | `:cacerts`, `:cacertfile` | the CA, for certificates from one |
  | `:fingerprint` | the SHA-256 of the PLC's self-signed certificate in hex, as TwinCAT shows it, or `:any` |
  | `:cert` and `:key`, or `:certfile` and `:keyfile` | the client's own certificate, for both kinds |
  | `:add_route` | `{user, password}` of a user on the PLC, to add a route for a self-signed certificate |
  | `:ignore_cn` | `true` for certificates that don't name their host: the PLC's isn't checked, and the PLC is asked not to check the client's |
  | `:ip_address` | `true` for a route that names the client by address rather than host name |
  | `:hostname` | the name the client gives, by default its host name |
  | `:ssl` | more options for OTP's `:ssl` |

  ## Options

    * `:host` - the PLC's host name or address (required)
    * `:net_id` - the PLC's AMS NetId, such as `"5.36.69.176.1.1"` (required, except with
      `secure:`)
    * `:ams_port` - the AMS port of the device (default 851, the first PLC runtime)
    * `:local_net_id` - the client's NetId, as the PLC's route has it (default the client's IP
      address on the connection, with `.1.1`)
    * `:local_ams_port` - the client's AMS port (default one picked from 32768 to 65535, the range
      for clients)
    * `:port` - the TCP port (default 48898, or 8016 with `secure:`)
    * `:secure` - Secure ADS, as above
    * `:timeout` - how long a request may take, in ms, waiting its turn included (default 5000)
    * `:max_pending` - how many requests may be on the way at once (default 32)
    * `:connect_timeout` - in ms (default 5000)
    * `:backoff` - `{first, longest}` wait between attempts to connect, in ms
      (default `{100, 5000}`)
    * `:max_size` - the most data an answer may have, in bytes (default 16 MB)
    * `:name` - to register the process
  """

  alias ADS.{DataType, NetId, Route, Sum, Symbol, Type}

  @backoff {100, 5_000}

  @handle_by_name 0xF003
  @value_by_handle 0xF005
  @release_handle 0xF006
  @symbol_by_name 0xF009
  @symbol_upload 0xF00B
  @upload_info 0xF00C
  @type_upload 0xF00E
  @upload_info2 0xF00F
  @type_by_name 0xF011

  # SYSTEMSERVICE_ENUMREMOTE, on the system service's port: a route for each index.
  @enum_remote 803
  @system_service 10000

  # Routes, so many and no more, of a system that never says it has none left; Beckhoff's
  # Tc2_Utilities has 99 at most.
  @max_routes 1000

  # What a device answers for a handle that has gone stale, or a variable whose type has changed,
  # as after an online change: the name is looked up again, once.
  @stale [
    :device_symbol_version_invalid,
    :device_symbol_not_found,
    :device_invalid_offset,
    :device_invalid_size,
    :device_notify_handle_invalid
  ]

  # What a device that has no sum commands answers one with.
  @no_sum [:device_service_not_supported, :device_invalid_group]

  # Types that refer to types that refer to types, so deep and no deeper.
  @max_depth 16

  # Whether a description a type refers to didn't come, while it's made out, in the caller.
  @unsure {__MODULE__, :unsure}

  @typedoc "A variable, by its name, or by index group and offset (which needs a type)."
  @type target :: String.t() | {ADS.index_group(), ADS.index_offset()}

  @typedoc "A target, and the type of its value if it's to be given rather than looked up."
  @type item :: target | {target, Type.t()}

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts a client, linked to the caller, with the options above. It returns at once, and connects
  in the background. Raises `ArgumentError` for options that don't make sense.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    config = config!(opts)
    name = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(ADS.Client.Connection, config, name)
  end

  @doc """
  Whether the client is connected: `:connected`, `:connecting`, or `{:disconnected, reason}` with
  the reason it last couldn't connect or lost its connection, such as `:econnrefused` or
  `:closed`.
  """
  @spec status(GenServer.server()) :: :connected | :connecting | {:disconnected, term}
  def status(client), do: GenServer.call(client, :status)

  @doc """
  The status, and the AMS addresses of both ends as `{net_id, port}`: the client's own, and the
  device's, once known.
  """
  @spec info(GenServer.server()) :: %{
          status: :connected | :connecting | {:disconnected, term},
          local: {ADS.net_id(), ADS.ams_port()} | nil,
          remote: {ADS.net_id(), ADS.ams_port()} | nil
        }
  def info(client), do: GenServer.call(client, :info)

  @doc """
  Closes the connection and stops the client, letting go of its handles and notifications: it
  waits for the device to close its end too, so that it has read them, for a second at most.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(client), do: GenServer.stop(client)

  @doc """
  Sends a request and waits for its result; see `ADS.Command` for both. `port:` sends it to
  another AMS port than the client's, and `timeout:` overrides the client's for it.

      ADS.Client.request(plc, {:read, 0x4020, 0, 4})
      ADS.Client.request(plc, :read_state, port: 10000)
  """
  @spec request(GenServer.server(), ADS.Command.request(), keyword) :: ADS.Command.result()
  def request(client, request, opts \\ []) do
    {port, encoded, timeout} = prepare!(request, opts)
    call(client, {:request, port, request, encoded, timeout, nil}, timeout)
  end

  @doc """
  Sends a request without waiting for it, and returns a reference. The result comes as a message
  to the caller, or to the process `to:` in `opts`:

      {ADS.Client, ref, result}

  It comes within the timeout, unless the client itself stops; monitor the client to hear of that.
  """
  @spec send_request(GenServer.server(), ADS.Command.request(), keyword) :: reference
  def send_request(client, request, opts \\ []) do
    {port, encoded, timeout} = prepare!(request, opts)
    ref = make_ref()

    GenServer.cast(
      client,
      {:request, port, request, encoded, timeout, Keyword.get(opts, :to, self()), ref}
    )

    ref
  end

  @doc "Reads the name and version of the device, such as `%{name: \"Plc30 App\", version: {3, 1, 4026}}`."
  @spec read_device_info(GenServer.server(), keyword) ::
          {:ok, %{name: String.t(), version: {byte, byte, 0..65535}}} | {:error, ADS.error()}
  def read_device_info(client, opts \\ []), do: request(client, :read_device_info, opts)

  @doc "Reads the ADS state of the device, `:run` for a running PLC, and its device state."
  @spec read_state(GenServer.server(), keyword) ::
          {:ok, %{ads_state: ADS.state(), device_state: 0..65535}} | {:error, ADS.error()}
  def read_state(client, opts \\ []), do: request(client, :read_state, opts)

  @doc """
  Changes the ADS state of the device: `:run` starts a PLC, `:stop` stops it, and `:reset` resets
  it. `device_state:` and `data:` go along, 0 and nothing by default.
  """
  @spec write_control(GenServer.server(), ADS.state(), keyword) :: :ok | {:error, ADS.error()}
  def write_control(client, ads_state, opts \\ []) do
    {device_state, opts} = Keyword.pop(opts, :device_state, 0)
    {data, opts} = Keyword.pop(opts, :data, <<>>)
    request(client, {:write_control, ads_state, device_state, data}, opts)
  end

  @doc """
  Reads a variable, by its name or by `{index_group, index_offset}` with `type:`, and gives its
  value as `ADS.Type` has it.
  """
  @spec read(GenServer.server(), target, keyword) :: {:ok, term} | {:error, ADS.error()}
  def read(client, target, opts \\ []) do
    {given, opts} = given!(opts)
    read_target(client, target!(target, given), given, opts, 1)
  end

  defp read_target(client, {:symbol, name} = target, given, opts, retries) do
    with {:ok, handle, type} <- entry(client, name, given, opts) do
      client
      |> request({:read, @value_by_handle, handle, Type.size(type)}, opts)
      |> decoded(type)
      |> again(retries, fn ->
        forget(client, name, opts)
        read_target(client, target, given, opts, retries - 1)
      end)
    end
  end

  defp read_target(client, {:address, group, offset}, type, opts, _retries),
    do: client |> request({:read, group, offset, Type.size(type)}, opts) |> decoded(type)

  defp decoded({:ok, data}, type) do
    case Type.decode(type, data) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_response, data}}
    end
  end

  defp decoded(error, _type), do: error

  defp again({:error, reason}, retries, again) when reason in @stale and retries > 0, do: again.()
  defp again(result, _retries, _again), do: result

  @doc """
  Writes a variable, by its name or by `{index_group, index_offset}` with `type:`. Raises
  `ArgumentError` for a value that doesn't fit its type, before writing anything.
  """
  @spec write(GenServer.server(), target, term, keyword) :: :ok | {:error, ADS.error()}
  def write(client, target, value, opts \\ []) do
    {given, opts} = given!(opts)
    write_target(client, target!(target, given), value, given, opts, 1)
  end

  defp write_target(client, {:symbol, name} = target, value, given, opts, retries) do
    with {:ok, handle, type} <- entry(client, name, given, opts) do
      client
      |> request({:write, @value_by_handle, handle, Type.encode(type, value)}, opts)
      |> again(retries, fn ->
        forget(client, name, opts)
        write_target(client, target, value, given, opts, retries - 1)
      end)
    end
  end

  defp write_target(client, {:address, group, offset}, value, type, opts, _retries),
    do: request(client, {:write, group, offset, Type.encode(type, value)}, opts)

  @doc """
  Reads many variables at once, each a name, or `{target, type}`, and gives a result for each, in
  order: `{:ok, value}` or `{:error, reason}`.

      {:ok, [{:ok, 1500}, {:error, :device_symbol_not_found}, {:ok, 42}]} =
        ADS.Client.read_many(plc, ["MAIN.nSpeed", "MAIN.nNone", {{0x4020, 0}, :dint}])
  """
  @spec read_many(GenServer.server(), [item], keyword) ::
          {:ok, [{:ok, term} | {:error, ADS.error()}]}
  def read_many(client, items, opts \\ []) when is_list(items) do
    items = Enum.map(items, &item!/1)
    resolved = resolve(client, items, opts)
    reads = for {:ok, entry} <- resolved, do: {entry.group, entry.offset, Type.size(entry.type)}

    results =
      merge(resolved, sum(client, :read, reads, opts), fn entry, result ->
        decoded(result, entry.type)
      end)

    results =
      for {{target, given, _original}, resolved, result} <- Enum.zip([items, resolved, results]) do
        case {target, resolved, result} do
          {{:symbol, name}, {:ok, _}, {:error, reason}} when reason in @stale ->
            forget(client, name, opts)
            read_target(client, target, given, opts, 0)

          _ ->
            result
        end
      end

    {:ok, results}
  end

  @doc """
  Writes many variables at once, each `{target, value}` or `{target, value, type}`, and gives a
  result for each, in order: `:ok` or `{:error, reason}`. Raises `ArgumentError` for a value that
  doesn't fit its type, before writing anything.
  """
  @spec write_many(GenServer.server(), [{target, term} | {target, term, Type.t()}], keyword) ::
          {:ok, [:ok | {:error, ADS.error()}]}
  def write_many(client, pairs, opts \\ []) when is_list(pairs) do
    items = Enum.map(pairs, &write_item!/1)
    resolved = resolve(client, Enum.map(items, fn {item, _value} -> item end), opts)

    encoded =
      for {{_item, value}, resolved} <- Enum.zip(items, resolved) do
        case resolved do
          {:ok, entry} -> {:ok, Map.put(entry, :data, Type.encode(entry.type, value))}
          error -> error
        end
      end

    writes = for {:ok, entry} <- encoded, do: {entry.group, entry.offset, entry.data}
    results = merge(encoded, sum(client, :write, writes, opts), fn _entry, result -> result end)

    results =
      for {{{target, given, _original}, value}, resolved, result} <-
            Enum.zip([items, encoded, results]) do
        case {target, resolved, result} do
          {{:symbol, name}, {:ok, _}, {:error, reason}} when reason in @stale ->
            forget(client, name, opts)
            write_target(client, target, value, given, opts, 0)

          _ ->
            result
        end
      end

    {:ok, results}
  end

  @doc """
  Asks the PLC to send the values of variables, each a name or `{target, type}`, to the
  subscriber; see "Notifications" above.

    * `:mode` - `:on_change`, the value when it changes, checked every cycle time (the default),
      or `:cyclic`, every cycle time
    * `:cycle_time` - in ms (default 100)
    * `:max_delay` - the longest the PLC may hold a value back, to send it along with others, in ms
      (default 0)
    * `:to` - the subscriber (default the caller)
  """
  @spec subscribe(GenServer.server(), item | [item], keyword) ::
          {:ok, reference} | {:error, ADS.error()}
  def subscribe(client, items, opts \\ []) do
    items = items |> List.wrap() |> Enum.map(&item!/1)
    {mode, max_delay, cycle_time} = notification!(opts)
    to = Keyword.get(opts, :to, self())

    with {:ok, entries} <- all_ok(resolve(client, items, opts)),
         ref when is_reference(ref) <- cache_call(client, {:subscribe, to}) do
      infos =
        for {{target, given, original}, entry} <- Enum.zip(items, entries) do
          %{
            key: make_ref(),
            target: original,
            symbol: symbol_name(target),
            given: given,
            type: entry.type,
            port: Keyword.get(opts, :port),
            group: entry.group,
            offset: entry.offset,
            mode: mode,
            max_delay: max_delay,
            cycle_time: cycle_time,
            handle: nil,
            at: nil
          }
        end

      case add_all(client, ref, infos, opts) do
        :ok ->
          {:ok, ref}

        error ->
          unsubscribe(client, ref)
          error
      end
    end
  end

  defp all_ok(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, for({:ok, entry} <- results, do: entry)}
      error -> error
    end
  end

  defp symbol_name({:symbol, name}), do: name
  defp symbol_name({:address, _group, _offset}), do: nil

  defp add_all(client, ref, infos, opts) do
    Enum.reduce_while(infos, :ok, fn info, :ok ->
      case add(client, ref, info, opts) do
        {:ok, _handle} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp add(client, ref, info, opts) do
    request =
      {:add_notification, info.group, info.offset, Type.size(info.type), info.mode,
       info.max_delay, info.cycle_time}

    {port, encoded, timeout} = prepare!(request, opts)
    call(client, {:request, port, request, encoded, timeout, {:notification, ref, info}}, timeout)
  end

  @doc "Ends a subscription, and asks the PLC to delete its notifications."
  @spec unsubscribe(GenServer.server(), reference) :: :ok
  def unsubscribe(client, ref) do
    _ = cache_call(client, {:unsubscribe, ref})
    :ok
  end

  @doc false
  # Adds a target's notification again, with a new handle for a name: after a reconnect, or when
  # the PLC said the old handle was no good. Run in a process of its own.
  def reestablish(connection, ref, info) do
    opts = [port: info.port]

    result =
      with {:ok, info} <- refreshed(connection, info, opts),
           do: add(connection, ref, info, opts)

    case result do
      {:ok, _handle} -> :ok
      # Tried again on the next connection.
      {:error, :closed} -> :ok
      {:error, reason} -> GenServer.cast(connection, {:lost, ref, info.key, reason})
    end
  end

  defp refreshed(_connection, %{symbol: nil} = info, _opts), do: {:ok, info}

  defp refreshed(connection, %{symbol: name} = info, opts) do
    with {:ok, handle, type} <- entry(connection, name, info.given, opts),
         do: {:ok, %{info | offset: handle, type: type}}
  end

  @doc """
  The PLC's description of a variable, by name; see `ADS.Symbol`.
  """
  @spec symbol(GenServer.server(), String.t(), keyword) ::
          {:ok, Symbol.t()} | {:error, ADS.error()}
  def symbol(client, name, opts \\ []) when is_binary(name) do
    with {:ok, data} <-
           request(client, {:read_write, @symbol_by_name, 0, 0xFFFF, name <> <<0>>}, opts),
         do: parsed(Symbol.decode(data), data)
  end

  @doc """
  The PLC's description of a data type, by name; see `ADS.DataType`.
  """
  @spec data_type(GenServer.server(), String.t(), keyword) ::
          {:ok, DataType.t()} | {:error, ADS.error()}
  def data_type(client, name, opts \\ []) when is_binary(name) do
    with {:ok, data} <-
           request(client, {:read_write, @type_by_name, 0, 0x100000, name <> <<0>>}, opts),
         do: parsed(DataType.decode(data), data)
  end

  @doc """
  The `ADS.Type` of a type name: built in, or as the PLC describes it, and those its description
  refers to. The client keeps the types it has looked up for as long as the connection lasts.

      {:ok, {:struct, 16, [{"nSpeed", 0, :int}, {"fTemp", 8, :lreal}]}} = ADS.Client.type(plc, "ST_Pump")
  """
  @spec type(GenServer.server(), String.t(), keyword) :: {:ok, Type.t()} | {:error, ADS.error()}
  def type(client, name, opts \\ []) when is_binary(name) do
    case resolve_type(client, name, nil, opts, 0) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :device_symbol_not_found}
      error -> error
    end
  end

  @doc """
  The routes of the system, as its system service lists them: the clients and systems it talks
  to, by name, NetId and address (see `ADS.Route`). `port:` asks another AMS port than 10000.

      {:ok, [%ADS.Route{name: "scada", net_id: "10.0.0.7.1.1", address: "10.0.0.7"} | _]} =
        ADS.Client.routes(plc)
  """
  @spec routes(GenServer.server(), keyword) :: {:ok, [Route.t()]} | {:error, ADS.error()}
  def routes(client, opts \\ []) do
    opts = Keyword.put_new(opts, :port, @system_service)
    each_route(client, opts, 0, [])
  end

  defp each_route(_client, _opts, @max_routes, routes), do: {:ok, Enum.reverse(routes)}

  defp each_route(client, opts, index, routes) do
    case request(client, {:read, @enum_remote, index, 2048}, opts) do
      {:ok, data} ->
        case Route.decode(data) do
          {:ok, route} -> each_route(client, opts, index + 1, [route | routes])
          :error -> {:error, {:invalid_response, data}}
        end

      {:error, :device_no_more_handles} ->
        {:ok, Enum.reverse(routes)}

      error ->
        error
    end
  end

  @doc "Uploads the descriptions of all the PLC's variables."
  @spec symbols(GenServer.server(), keyword) :: {:ok, [Symbol.t()]} | {:error, ADS.error()}
  def symbols(client, opts \\ []) do
    with {:ok, info} <- upload_info(client, opts),
         {:ok, data} <- request(client, {:read, @symbol_upload, 0, info.symbol_size}, opts),
         do: parsed(Symbol.decode_all(data), data)
  end

  @doc "Uploads the descriptions of all the PLC's data types."
  @spec data_types(GenServer.server(), keyword) :: {:ok, [DataType.t()]} | {:error, ADS.error()}
  def data_types(client, opts \\ []) do
    with {:ok, %{type_size: size}} when is_integer(size) <- upload_info(client, opts),
         {:ok, data} <- request(client, {:read, @type_upload, 0, size}, opts) do
      parsed(DataType.decode_all(data), data)
    else
      {:ok, %{type_size: nil}} -> {:error, :device_service_not_supported}
      error -> error
    end
  end

  # How many symbols and data types there are, and the size of their descriptions; from a device
  # that doesn't have the second kind of upload info, the symbols' only.
  defp upload_info(client, opts) do
    case upload_info2(client, opts) do
      {:ok,
       <<symbols::32-little, symbol_size::32-little, types::32-little, type_size::32-little,
         _::binary>>} ->
        {:ok, %{symbols: symbols, symbol_size: symbol_size, types: types, type_size: type_size}}

      {:error, reason} when reason in @no_sum ->
        case request(client, {:read, @upload_info, 0, 8}, opts) do
          {:ok, <<symbols::32-little, symbol_size::32-little>>} ->
            {:ok, %{symbols: symbols, symbol_size: symbol_size, types: nil, type_size: nil}}

          {:ok, data} ->
            {:error, {:invalid_response, data}}

          error ->
            error
        end

      {:ok, data} ->
        {:error, {:invalid_response, data}}

      error ->
        error
    end
  end

  # Of the second kind, 24 bytes are read, but asked for are 64, as Beckhoff's own client does and
  # its servers want; 24 of a device that has no more.
  defp upload_info2(client, opts) do
    case request(client, {:read, @upload_info2, 0, 64}, opts) do
      {:error, :device_invalid_size} -> request(client, {:read, @upload_info2, 0, 24}, opts)
      result -> result
    end
  end

  defp parsed({:ok, value}, _data), do: {:ok, value}
  defp parsed(:error, data), do: {:error, {:invalid_response, data}}

  # The handle of a name and its type, given or as the PLC describes it; both kept by the client.
  defp entry(client, name, given, opts) do
    case resolve(client, [{{:symbol, name}, given, name}], opts) do
      [{:ok, %{offset: handle, type: type}}] -> {:ok, handle, type}
      [error] -> error
    end
  end

  # Each item as {:ok, %{group, offset, type}}, or an error. For names, the handles and types the
  # client has are used, and those it doesn't come from the PLC: the descriptions with requests on
  # the way at once, and the handles in sum commands.
  defp resolve(client, items, opts) do
    names = for {{:symbol, name}, given, _} <- items, uniq: true, do: {name, given}
    entries = names(client, names, opts)

    for {target, given, _original} <- items, do: resolved(target, given, entries)
  end

  defp resolved({:address, group, offset}, given, _entries),
    do: {:ok, %{group: group, offset: offset, type: given}}

  defp resolved({:symbol, name}, given, entries) do
    with {:ok, handle, type} <- Map.fetch!(entries, {name, given}),
         do: {:ok, %{group: @value_by_handle, offset: handle, type: type}}
  end

  defp names(_client, [], _opts), do: %{}

  defp names(client, pairs, opts) do
    cached = cached(client, pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), opts)

    untyped = for {name, nil} <- pairs, not typed?(cached[name]), uniq: true, do: name

    types =
      Map.new(pipelined(client, untyped, &symbol_request/1, opts), fn {name, result} ->
        {name, symbol_type(client, result, opts)}
      end)

    unhandled =
      for {name, given} <- pairs,
          cached[name] == nil,
          given != nil or match?({:ok, _}, types[name]),
          uniq: true,
          do: name

    handles = new_handles(client, unhandled, types, opts)

    Map.new(pairs, fn {name, _given} = pair ->
      {pair, entry(client, pair, cached[name], types, handles, opts)}
    end)
  end

  defp typed?(%{type: type}) when type != nil, do: true
  defp typed?(_cached), do: false

  # A name's handle and type: as given, as the client kept them, or as just looked up.
  defp entry(client, {name, given}, cached, types, handles, opts) do
    type =
      cond do
        given != nil -> {:ok, given}
        typed?(cached) -> {:ok, cached.type}
        true -> types[name]
      end

    handle = if cached, do: {:ok, cached.handle}, else: Map.get(handles, name, {:error, :closed})

    with {:ok, type} <- type,
         {:ok, handle} <- handle do
      # A name kept without its type, as given, gets it now it's looked up.
      _ =
        if cached != nil and given == nil and cached.type == nil,
          do: remember(client, name, handle, type, opts)

      {:ok, handle, type}
    end
  end

  defp symbol_request(name), do: {:read_write, @symbol_by_name, 0, 0xFFFF, name <> <<0>>}

  defp symbol_type(client, result, opts) do
    with {:ok, data} <- result,
         {:ok, symbol} <- parsed(Symbol.decode(data), data),
         do: surely(fn -> type_of(client, symbol, opts) end)
  end

  # New handles, in sum commands, each kept by the client with its type if it was looked up; one
  # another caller got first is kept instead, and the new one let go of.
  defp new_handles(_client, [], _types, _opts), do: %{}

  defp new_handles(client, names, types, opts) do
    results =
      sum(
        client,
        :read_write,
        for(name <- names, do: {@handle_by_name, 0, 4, name <> <<0>>}),
        opts
      )

    for {name, result} <- Enum.zip(names, results), into: %{} do
      case result do
        {:ok, <<handle::32-little>>} ->
          {name, remember(client, name, handle, looked_up(types[name]), opts)}

        {:ok, data} ->
          {name, {:error, {:invalid_response, data}}}

        error ->
          {name, error}
      end
    end
  end

  defp looked_up({:ok, type}), do: type
  defp looked_up(_given_or_failed), do: nil

  defp remember(client, name, handle, type, opts) do
    case cache_call(client, {:remember, opts[:port], name, handle, type}) do
      {:ok, handle} ->
        {:ok, handle}

      {:existing, existing} ->
        _ = request(client, {:write, @release_handle, 0, <<handle::32-little>>}, opts)
        {:ok, existing}

      _closed ->
        {:error, :closed}
    end
  end

  defp cached(client, names, opts) do
    case cache_call(client, {:handles, opts[:port], names}) do
      cached when is_map(cached) -> cached
      _closed -> %{}
    end
  end

  defp forget(client, name, opts), do: cache_call(client, {:forget, opts[:port], name})

  # The type of a symbol: by its type's name, built in or described by the PLC, if it's of the
  # symbol's size; else by its data type id; else its bytes.
  defp type_of(client, symbol, opts) do
    type =
      case resolve_type(client, symbol.type, symbol.size, opts, 0) do
        {:ok, type} -> if Type.size(type) == symbol.size, do: type
        _ -> nil
      end

    case type || Type.from_id(symbol.data_type, symbol.size) || {:raw, symbol.size} do
      {:string, n} -> if utf8?(symbol.attributes), do: {:string, n, :utf8}, else: {:string, n}
      type -> type
    end
  end

  defp utf8?(attributes) do
    Enum.any?(attributes, fn {name, value} ->
      String.downcase(name) == "tcencoding" and String.upcase(value) == "UTF-8"
    end)
  end

  defp resolve_type(client, name, size, opts, depth) do
    case Type.parse(name, size) do
      {:ok, type} ->
        {:ok, type}

      :error when depth >= @max_depth ->
        :error

      :error ->
        case cache_call(client, {:type, opts[:port], name}) do
          {:ok, type} -> {:ok, type}
          _ -> described_type(client, name, opts, depth)
        end
    end
  end

  # A type the PLC describes, kept by the client once it's made out. A description it refers to
  # that doesn't come, as on a connection going wrong, makes it an error, rather than a type with
  # a stand-in, such as a number for an enumeration, kept for good.
  defp described_type(client, name, opts, depth) do
    resolve = &resolve_type(client, &1, &2, opts, depth + 1)

    with {:ok, data_type} <- came(data_type(client, name, opts)),
         {:ok, type} <- surely(fn -> DataType.to_type(data_type, resolve) end) do
      _ = cache_call(client, {:remember_type, opts[:port], name, type})
      {:ok, type}
    end
  end

  # A description that didn't come makes what asked for it unsure.
  defp came({:error, reason} = error) when reason in [:timeout, :closed] do
    if Process.get(@unsure, :none) == nil, do: Process.put(@unsure, reason)
    error
  end

  defp came(result), do: result

  # What fun gives, unless a description it asked for didn't come, then why; those asked for in
  # turn count for the one that asked.
  defp surely(fun) do
    outer = Process.get(@unsure, :none)
    Process.put(@unsure, nil)
    result = fun.()
    reason = Process.get(@unsure)

    _ =
      if outer == :none, do: Process.delete(@unsure), else: Process.put(@unsure, outer || reason)

    if reason, do: {:error, reason}, else: {:ok, result}
  end

  # A sum command for each 500 items, or a request of its own for one alone or for each with a
  # device that has no sum commands; a result for each item, in order.
  defp sum(_client, _kind, [], _opts), do: []

  defp sum(client, kind, items, opts) do
    items
    |> Enum.chunk_every(Sum.max())
    |> Enum.flat_map(fn
      [item] ->
        singles(client, kind, [item], opts)

      chunk ->
        with {:ok, data} <- request(client, sum_request(kind, chunk), opts),
             {:ok, results} <- decode_sum(kind, chunk, data) do
          results
        else
          {:error, reason} when reason in @no_sum -> singles(client, kind, chunk, opts)
          error -> List.duplicate(error, length(chunk))
        end
    end)
  end

  defp sum_request(:read, chunk), do: Sum.read(chunk)
  defp sum_request(:write, chunk), do: Sum.write(chunk)
  defp sum_request(:read_write, chunk), do: Sum.read_write(chunk)

  defp decode_sum(:read, chunk, data), do: Sum.decode_read(chunk, data)
  defp decode_sum(:write, chunk, data), do: Sum.decode_write(chunk, data)
  defp decode_sum(:read_write, chunk, data), do: Sum.decode_read_write(chunk, data)

  defp singles(client, kind, items, opts) do
    items
    |> Enum.with_index()
    |> then(&pipelined(client, &1, fn {item, _index} -> single(kind, item) end, opts))
    |> Enum.map(fn {_key, result} -> result end)
  end

  defp single(:read, {group, offset, length}), do: {:read, group, offset, length}
  defp single(:write, {group, offset, data}), do: {:write, group, offset, data}

  defp single(:read_write, {group, offset, length, data}),
    do: {:read_write, group, offset, length, data}

  # Requests on the way at once, a result for each key, in order. The client answers each within
  # its timeout, unless it stops, which the monitor hears of.
  defp pipelined(_client, [], _request, _opts), do: []

  defp pipelined(client, keys, request, opts) do
    case GenServer.whereis(client) do
      pid when is_pid(pid) ->
        monitor = Process.monitor(pid)
        # The results come here, whoever a subscription's to: names.
        opts = Keyword.put(opts, :to, self())
        refs = for key <- keys, do: {key, send_request(pid, request.(key), opts)}

        {results, _down} =
          Enum.map_reduce(refs, false, fn {key, ref}, down ->
            {result, down} = await(ref, monitor, down)
            {{key, result}, down}
          end)

        Process.demonitor(monitor, [:flush])
        results

      _ ->
        for key <- keys, do: {key, {:error, :closed}}
    end
  end

  # A result that has come; else the one to come, unless the client is down.
  defp await(ref, monitor, down) do
    receive do
      {ADS.Client, ^ref, result} -> {result, down}
    after
      0 -> if down, do: {{:error, :closed}, true}, else: await(ref, monitor)
    end
  end

  defp await(ref, monitor) do
    receive do
      {ADS.Client, ^ref, result} -> {result, false}
      {:DOWN, ^monitor, :process, _, _} -> {{:error, :closed}, true}
    end
  end

  # Each result in place of an entry that was asked for; errors from looking up stay.
  defp merge(resolved, results, fun) do
    {merged, []} =
      Enum.map_reduce(resolved, results, fn
        {:ok, entry}, [result | results] -> {fun.(entry, result), results}
        error, results -> {error, results}
      end)

    merged
  end

  defp prepare!(request, opts) do
    port = Keyword.get(opts, :port)

    if port != nil and not (is_integer(port) and port in 0..65535),
      do: raise(ArgumentError, "port: must be an AMS port, 0 to 65535, got: #{inspect(port)}")

    timeout = Keyword.get(opts, :timeout)

    if timeout != nil and not (is_integer(timeout) and timeout > 0),
      do:
        raise(ArgumentError, "timeout: must be a positive number of ms, got: #{inspect(timeout)}")

    {port, ADS.Command.encode_request(request), timeout}
  end

  defp call(client, message, timeout) do
    GenServer.call(client, message, call_timeout(timeout))
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :closed}
  end

  defp cache_call(client, message) do
    GenServer.call(client, message)
  catch
    :exit, _reason -> {:error, :closed}
  end

  # The client answers within the request's timeout; the margin is for a client that's swamped.
  defp call_timeout(nil), do: :infinity
  defp call_timeout(timeout), do: timeout + 1000

  defp given!(opts) do
    case Keyword.pop(opts, :type) do
      {nil, opts} -> {nil, opts}
      {type, opts} -> {Type.check!(type), opts}
    end
  end

  defguardp u32(n) when is_integer(n) and n in 0..0xFFFFFFFF

  defp target!(name, _given) when is_binary(name), do: {:symbol, name}

  defp target!({group, offset}, given) when u32(group) and u32(offset) do
    if given == nil, do: raise(ArgumentError, "an index group and offset need type:")
    {:address, group, offset}
  end

  defp target!(target, _given),
    do:
      raise(
        ArgumentError,
        "a target is a name, or {index_group, index_offset}, got: #{inspect(target)}"
      )

  defp item!({target, type})
       when is_binary(target) or (is_tuple(target) and tuple_size(target) == 2),
       do: {target!(target, Type.check!(type)), type, target}

  defp item!(name) when is_binary(name), do: {{:symbol, name}, nil, name}

  defp item!(item),
    do: raise(ArgumentError, "an item is a name, or {target, type}, got: #{inspect(item)}")

  defp write_item!({target, value}), do: {item!(target), value}
  defp write_item!({target, value, type}), do: {item!({target, type}), value}

  defp write_item!(pair),
    do:
      raise(
        ArgumentError,
        "a write is {target, value} or {target, value, type}, got: #{inspect(pair)}"
      )

  defp notification!(opts) do
    mode = Keyword.get(opts, :mode, :on_change)

    if mode not in [:on_change, :cyclic],
      do: raise(ArgumentError, "mode: is :on_change or :cyclic, got: #{inspect(mode)}")

    {mode, ms!(opts, :max_delay, 0), ms!(opts, :cycle_time, 100)}
  end

  # In ms here, in 100 ns on the wire.
  defp ms!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      ms when is_integer(ms) and ms >= 0 and ms * 10_000 <= 0xFFFFFFFF -> ms * 10_000
      ms -> raise ArgumentError, "#{key}: must be 0 to 429496 ms, got: #{inspect(ms)}"
    end
  end

  defp config!(opts) do
    if not Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options")

    known = [
      :host,
      :net_id,
      :ams_port,
      :local_net_id,
      :local_ams_port,
      :port,
      :secure,
      :timeout,
      :max_pending,
      :connect_timeout,
      :backoff,
      :max_size,
      :name
    ]

    case Enum.uniq(Keyword.keys(opts)) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options: #{inspect(unknown)}"
    end

    secure = if Keyword.has_key?(opts, :secure), do: ADS.Secure.config!(opts[:secure])

    %{
      host: host!(Keyword.get(opts, :host)),
      port: port!(Keyword.get(opts, :port, if(secure, do: 8016, else: 48898)), :port),
      net_id: net_id!(Keyword.get(opts, :net_id), secure),
      ams_port: port!(Keyword.get(opts, :ams_port, 851), :ams_port),
      local_net_id: if(opts[:local_net_id], do: NetId.parse!(opts[:local_net_id])),
      local_ams_port:
        port!(
          Keyword.get_lazy(opts, :local_ams_port, fn -> 32767 + :rand.uniform(32768) end),
          :local_ams_port
        ),
      timeout: positive!(opts, :timeout, 5000),
      max_pending: positive!(opts, :max_pending, 32),
      connect_timeout: positive!(opts, :connect_timeout, 5000),
      backoff: backoff!(Keyword.get(opts, :backoff, @backoff)),
      max_size: positive!(opts, :max_size, 16 * 1024 * 1024),
      secure: secure
    }
  end

  defp net_id!(nil, nil), do: raise(ArgumentError, "net_id: is required, except with secure:")
  defp net_id!(nil, _secure), do: nil
  defp net_id!(net_id, _secure), do: NetId.parse!(net_id)

  # An address as a string, IPv6 included, is taken as the address; anything else is a name.
  defp host!(host) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> address
      {:error, _not_an_address} -> String.to_charlist(host)
    end
  end

  defp host!(host) when is_tuple(host) and tuple_size(host) in [4, 8], do: host
  defp host!(nil), do: raise(ArgumentError, "host: is required")

  defp host!(host),
    do: raise(ArgumentError, "a host is a name or an address, got: #{inspect(host)}")

  defp port!(port, _key) when is_integer(port) and port in 0..65535, do: port

  defp port!(port, key),
    do: raise(ArgumentError, "#{key}: must be 0 to 65535, got: #{inspect(port)}")

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key}: must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp backoff!({first, longest} = backoff)
       when is_integer(first) and first > 0 and is_integer(longest) and longest >= first,
       do: backoff

  defp backoff!(backoff),
    do: raise(ArgumentError, "backoff: must be {first, longest} in ms, got: #{inspect(backoff)}")
end
