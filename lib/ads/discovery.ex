defmodule ADS.Discovery do
  @moduledoc """
  Finding ADS devices on the network, and adding routes to them, over UDP port 48899, as
  TwinCAT's own Broadcast Search and Add Route do:

      {:ok, [%{address: {10, 0, 0, 5}, net_id: "5.36.69.176.1.1"}]} = ADS.Discovery.search()
      {:ok, %{net_id: "5.36.69.176.1.1"}} = ADS.Discovery.info("10.0.0.5")
      :ok = ADS.Discovery.add_route("10.0.0.5", password: "1")

  A PLC lets in only clients it has a route for: their AMS NetId, and the address they come from.
  `add_route/2` adds one with the login of a user on the PLC, Administrator unless told otherwise,
  for the NetId the client is to use, by default its address with `.1.1` as `ADS.Client` takes
  it, so that a client can connect after without TwinCAT's tools. The password goes over the
  network as it is, as with TwinCAT's tools; Secure ADS adds routes inside TLS instead (see
  `ADS.Secure`).

  Beckhoff's manuals say only that discovery goes over UDP port 48899. What goes in it follows
  Beckhoff's own ADS library ([github.com/Beckhoff/ADS](https://github.com/Beckhoff/ADS), MIT
  License), which asks a device for its NetId over it, and adds routes; deleting them follows
  Apache PLC4X's description of the protocol ([plc4x.apache.org](https://plc4x.apache.org),
  Apache License 2.0). Each datagram, request or answer, is:

  | Bytes | Field |
  |---|---|
  | 4 | `0x71146603` |
  | 4 | an invoke id, 0, which the answer has too |
  | 4 | the service: 1 for a device's info, 6 to add a route, 7 to delete one; with `0x80000000` added in the answer |
  | 6, 2 | an AMS NetId and port, the sender's: in a request to add a route, the route's NetId |
  | 4 | the number of tags |
  | ... | the tags, each a 2-byte id, the length of its value in 2 bytes, and the value |

  To add or delete a route, the tags are the route's name (12), its NetId (7), the user (13), the
  password (2) and the client's address (5), the strings with a zero after them, in Windows-1252
  here as in Secure ADS; the answer's tag 1 is its result, a return code of 4 bytes. All numbers
  are little-endian.

  An answer is taken only from the address asked, with the service and invoke id of the request;
  anything else that comes is passed over. Nothing sent is ever empty, which older TwinCAT
  routers stopped at (Beckhoff's advisory 2019-004).
  """

  import Bitwise

  alias ADS.{NetId, ReturnCode}

  @port 48899
  @cookie 0x71146603
  @info 1
  @add_route 6
  @delete_route 7
  @response 0x80000000

  @result 1
  @password 2
  @version 3
  @computer_name 5
  @net_id 7
  @route_name 12
  @user 13
  @fingerprint 18

  # Answers to a search, so many and no more.
  @max_devices 1000

  @typedoc """
  A device that answered: its IP address, AMS NetId, and the tags of its answer, `{id, value}`,
  and of those, as TwinCAT 3.1 4026 has them:

    * `name` - its name, tag 5, the tag of a computer's name in a route
    * `version` - TwinCAT's, tag 3, such as `{3, 1, 4026}`
    * `fingerprint` - the SHA-256 of its certificate for Secure ADS, tag 18, in hex as TwinCAT
      shows it and `secure: [fingerprint: ...]` takes it. It comes over UDP, which anyone on the
      network can answer: compare it with the one TwinCAT shows before trusting it.

  Each is `nil` if the device doesn't give it.
  """
  @type device :: %{
          address: :inet.ip4_address(),
          net_id: ADS.net_id(),
          name: String.t() | nil,
          version: {byte, byte, 0..65535} | nil,
          fingerprint: String.t() | nil,
          tags: [{0..65535, binary}]
        }

  @typedoc "A datagram, as `encode/1` takes it, its invoke id 0 if left out, and `decode/1` gives it."
  @type datagram :: %{
          required(:service) => 0..0xFFFFFFFF,
          optional(:invoke_id) => 0..0xFFFFFFFF,
          required(:net_id) => NetId.t(),
          required(:port) => ADS.ams_port(),
          required(:tags) => [{0..65535, binary}]
        }

  @doc """
  Asks every device on the network for its info, and gives those that answer in time, in the
  order they did. A firewall on this machine that lets in only answers to what was sent, as ufw
  does, drops theirs, as they come from another address than the broadcast went to; `info/2`
  asks one device by its address, and its answer gets through.

    * `:to` - the addresses to ask, broadcast or not (default `{255, 255, 255, 255}`, and the
      broadcast address of each network this machine is on)
    * `:port` - the UDP port (default 48899)
    * `:timeout` - how long to wait for answers, in ms (default 2000)
  """
  @spec search(keyword) :: {:ok, [device]} | {:error, :inet.posix()}
  def search(opts \\ []) do
    check!(opts, [:to, :port, :timeout])
    addresses = opts |> Keyword.get_lazy(:to, &broadcasts/0) |> Enum.map(&resolve/1)
    port = port!(opts)
    deadline = deadline(Keyword.get(opts, :timeout, 2000))

    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: false, broadcast: true]) do
      try do
        request = encode(%{service: @info, net_id: <<0::48>>, port: 0, tags: []})
        for {:ok, ip} <- addresses, do: _ = :gen_udp.send(socket, ip, port, request)
        {:ok, socket |> devices(port, deadline, []) |> Enum.uniq_by(&{&1.address, &1.net_id})}
      after
        :gen_udp.close(socket)
      end
    end
  end

  # 255.255.255.255 goes out on one network only, the default route's, so each network's own
  # broadcast address too.
  defp broadcasts do
    interfaces =
      case :inet.getifaddrs() do
        {:ok, interfaces} -> interfaces
        {:error, _} -> []
      end

    found =
      for {_name, props} <- interfaces,
          flags = Keyword.get(props, :flags, []),
          :up in flags and :broadcast in flags,
          {:broadaddr, {_, _, _, _} = address} <- props,
          do: address

    Enum.uniq([{255, 255, 255, 255} | found])
  end

  defp devices(_socket, _port, _deadline, devices) when length(devices) >= @max_devices,
    do: Enum.reverse(devices)

  defp devices(socket, port, deadline, devices) do
    with remaining when remaining > 0 <- deadline - now(),
         {:ok, {{_, _, _, _} = ip, ^port, data}} <- :gen_udp.recv(socket, 0, remaining) do
      case answer(data, @info) do
        {:ok, answer} -> devices(socket, port, deadline, [device(ip, answer) | devices])
        :error -> devices(socket, port, deadline, devices)
      end
    else
      {:ok, _from_elsewhere} -> devices(socket, port, deadline, devices)
      _timeout_or_closed -> Enum.reverse(devices)
    end
  end

  @doc """
  Asks one device for its info: its AMS NetId above all.

    * `:port` - the UDP port (default 48899)
    * `:timeout` - in ms (default 5000)
  """
  @spec info(String.t() | :inet.ip4_address(), keyword) :: {:ok, device} | {:error, term}
  def info(host, opts \\ []) do
    check!(opts, [:port, :timeout])

    request = fn _local -> %{service: @info, net_id: <<0::48>>, port: 0, tags: []} end

    with {:ok, ip} <- resolve(host),
         {:ok, answer, _data} <- exchange(ip, opts, request),
         do: {:ok, device(ip, answer)}
  end

  @doc """
  Adds a route on a device, for a client to connect with.

    * `:password` - of the user on the device (required)
    * `:user` - (default `"Administrator"`)
    * `:net_id` - the client's NetId, as it's to start with `local_net_id:` if it's not the
      default: its address with `.1.1`
    * `:address` - the client's address, as the device is to know it (default the address it
      sends from)
    * `:name` - the route's name (default the address)
    * `:port` - the UDP port (default 48899)
    * `:timeout` - in ms (default 5000)

  `:ok` once the device has added the route, or `{:error, reason}`: an ADS return code if it
  wouldn't, such as for a wrong password, or `:timeout`.
  """
  @spec add_route(String.t() | :inet.ip4_address(), keyword) :: :ok | {:error, term}
  def add_route(host, opts), do: route(host, opts, @add_route)

  @doc """
  Deletes a route on a device, with the login of a user on it, as `add_route/2` adds one and with
  the same options. TwinCAT 3.1 4026 deletes the route of the name, by default the address, as
  `add_route/2` names it: give the name it was added with. Another route with the same NetId stays.

  `:ok` once the device has deleted it, or `{:error, reason}` as for `add_route/2`:
  `:device_not_found` from Beckhoff's own system service for a route it hasn't. Beckhoff's router
  lets a connection that's open stay, its route deleted.
  """
  @spec delete_route(String.t() | :inet.ip4_address(), keyword) :: :ok | {:error, term}
  def delete_route(host, opts), do: route(host, opts, @delete_route)

  # A request to add or delete a route, which differ only in their service.
  defp route(host, opts, service) do
    check!(opts, [:password, :user, :net_id, :address, :name, :port, :timeout])
    password = Keyword.get(opts, :password) || raise ArgumentError, "password: is required"
    user = Keyword.get(opts, :user, "Administrator")
    net_id = if net_id = opts[:net_id], do: NetId.parse!(net_id)

    request = fn local ->
      address = opts |> Keyword.get(:address, local) |> address_string!()

      %{
        service: service,
        net_id: net_id || NetId.from_ip(local),
        port: 0,
        tags: [
          {@route_name, string!(Keyword.get(opts, :name, address))},
          {@net_id, net_id || NetId.from_ip(local)},
          {@user, string!(user)},
          {@password, string!(password)},
          {@computer_name, string!(address)}
        ]
      }
    end

    with {:ok, ip} <- resolve(host),
         {:ok, answer, data} <- exchange(ip, opts, request) do
      case List.keyfind(answer.tags, @result, 0) do
        {@result, <<0::32>>} -> :ok
        {@result, <<code::32-little>>} -> {:error, ReturnCode.name(code)}
        _ -> {:error, {:invalid_response, data}}
      end
    end
  end

  # One request, to one device, and its answer, decoded and as it came. The request is made once
  # the client's own address towards the device is known.
  defp exchange(ip, opts, request) do
    port = port!(opts)
    deadline = deadline(Keyword.get(opts, :timeout, 5000))

    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]) do
      try do
        with :ok <- :gen_udp.connect(socket, ip, port),
             {:ok, {local, _port}} <- :inet.sockname(socket),
             datagram = request.(local),
             :ok <- :gen_udp.send(socket, encode(datagram)),
             do: await(socket, {ip, port}, datagram.service, deadline)
      after
        :gen_udp.close(socket)
      end
    end
  end

  defp await(socket, {ip, port} = from, service, deadline) do
    with remaining when remaining > 0 <- deadline - now(),
         {:ok, {^ip, ^port, data}} <- :gen_udp.recv(socket, 0, remaining),
         {:ok, answer} <- answer(data, service) do
      {:ok, answer, data}
    else
      remaining when is_integer(remaining) -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
      _not_the_answer -> await(socket, from, service, deadline)
    end
  end

  defp answer(data, service) do
    case decode(data) do
      {:ok, %{service: answered, invoke_id: 0} = answer}
      when answered == (@response ||| service) ->
        {:ok, answer}

      _ ->
        :error
    end
  end

  defp device(ip, answer) do
    tag = fn id -> with {^id, value} <- List.keyfind(answer.tags, id, 0), do: value end

    %{
      address: ip,
      net_id: NetId.to_string(answer.net_id),
      name: if(name = tag.(@computer_name), do: name |> cstring() |> ADS.Secure.ansi()),
      version: version(tag.(@version)),
      fingerprint: fingerprint(tag.(@fingerprint)),
      tags: answer.tags
    }
  end

  defp cstring(value), do: value |> :binary.split(<<0>>) |> hd()

  defp version(<<major, minor, build::16-little, _::binary>>), do: {major, minor, build}
  defp version(_none), do: nil

  # 64 hex digits, as 32 pairs with colons between.
  defp fingerprint(value) when is_binary(value) do
    hex = value |> cstring() |> String.upcase()

    if byte_size(hex) == 64 and match?({:ok, _}, Base.decode16(hex)),
      do: for(<<pair::binary-2 <- hex>>, do: pair) |> Enum.join(":")
  end

  defp fingerprint(_none), do: nil

  @doc "A datagram as bytes to send."
  @spec encode(datagram) :: binary
  def encode(%{service: service, net_id: <<_::48>> = net_id, port: port, tags: tags} = datagram) do
    invoke_id = Map.get(datagram, :invoke_id, 0)

    body =
      for {id, value} <- tags, into: <<>> do
        <<id::16-little, byte_size(value)::16-little, value::binary>>
      end

    <<@cookie::32-little, invoke_id::32-little, service::32-little, net_id::binary,
      port::16-little, length(tags)::32-little, body::binary>>
  end

  @doc """
  A datagram that came, or `:error` if it isn't one. Its tags are read as far as they go, and as
  many as it says it has, at most.
  """
  @spec decode(binary) :: {:ok, datagram} | :error
  def decode(
        <<@cookie::32-little, invoke_id::32-little, service::32-little, net_id::binary-6,
          port::16-little, rest::binary>>
      ) do
    tags =
      case rest do
        <<count::32-little, tags::binary>> -> tags(tags, count, [])
        _ -> []
      end

    {:ok, %{service: service, invoke_id: invoke_id, net_id: net_id, port: port, tags: tags}}
  end

  def decode(_bytes), do: :error

  defp tags(
         <<id::16-little, length::16-little, value::binary-size(length), rest::binary>>,
         n,
         tags
       )
       when n > 0,
       do: tags(rest, n - 1, [{id, value} | tags])

  defp tags(_rest, _n, tags), do: Enum.reverse(tags)

  defp string!(string) do
    bytes = ADS.Secure.ansi!(string) <> <<0>>

    if byte_size(bytes) > 65535,
      do: raise(ArgumentError, "a string of at most 65534 bytes, got #{byte_size(bytes) - 1}")

    bytes
  end

  defp resolve({_, _, _, _} = ip), do: {:ok, ip}
  defp resolve(host) when is_binary(host), do: :inet.getaddr(String.to_charlist(host), :inet)

  defp resolve(host),
    do: raise(ArgumentError, "expected an IPv4 address or a host, got: #{inspect(host)}")

  defp address_string!({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> List.to_string()
  defp address_string!(address) when is_binary(address), do: address

  defp address_string!(address),
    do:
      raise(
        ArgumentError,
        "address: must be a string or an IPv4 address, got: #{inspect(address)}"
      )

  defp port!(opts) do
    case Keyword.get(opts, :port, @port) do
      port when port in 1..65535 -> port
      port -> raise ArgumentError, "port: must be a UDP port, got: #{inspect(port)}"
    end
  end

  defp deadline(timeout) when is_integer(timeout) and timeout > 0, do: now() + timeout

  defp deadline(timeout),
    do: raise(ArgumentError, "timeout: must be a positive number of ms, got: #{inspect(timeout)}")

  defp check!(opts, known) do
    if not Keyword.keyword?(opts), do: raise(ArgumentError, "expected a keyword list of options")

    case Enum.uniq(Keyword.keys(opts)) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options: #{inspect(unknown)}"
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
