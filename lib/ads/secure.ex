defmodule ADS.Secure do
  @moduledoc """
  Secure ADS: ADS inside TLS 1.2, to port 8016, from TwinCAT 3.1 build 4024 on.

  Beckhoff's manual, "TwinCAT 3 Secure ADS", describes the three ways the two ends agree on keys,
  and how to set them up on the PLC; what goes inside the TLS connection it leaves out. That part
  is as described by https://github.com/kevinherron/beckhoff-secure-ads, and is yet to be checked
  against a PLC:

    1. TLS 1.2, with a certificate on both sides, or a pre-shared key.
    2. The client sends a TlsConnectInfo, and the PLC answers with one (`connect_info/4`).
    3. AMS packets follow, each without the AMS/TCP header in front, as the AMS header holds
       their length (see `ADS.AMS`).

  | Mode | Keys | On the PLC |
  |---|---|---|
  | Pre-shared key | an identity and a password, and TLS-PSK with the key `psk_key/2` | an entry under Server/Tls/Psk in its StaticRoutes.xml |
  | Shared CA | a certificate for each side from a CA both trust | the CA, its own certificate and key under Server/Tls |
  | Self-signed | each side its own certificate, the PLC's known by its SHA-256 fingerprint | a route, added once with the login of a user on the PLC (`add_route:`) |

  A TlsConnectInfo is 64 bytes, with a user's name and password after them when adding a route:

  | Bytes | Field |
  |---|---|
  | 2 | length, 64 and the credentials |
  | 2 | flags |
  | 1 | version, 1 |
  | 1 | error, in the PLC's answer: 0, or 1 for the TLS version, 2 a certificate's name, 3 an unknown certificate, 4 an unknown user |
  | 6 | the NetId of the sender |
  | 1, 1 | lengths of the user name and the password |
  | 18 | reserved, zeros |
  | 32 | the sender's host name, with zeros after |
  | ... | the user name and the password |

  Its strings are in Windows-1252, as are the PSK identity and password.

  The flags are, from the lowest bit: `:response`, in the PLC's answer; `:ams_allowed`;
  `:server_info`; `:own_file`; `:self_signed`, for self-signed certificates; `:ip_address`, for a
  route that names the client by its address rather than its host name; `:ignore_cn`, for
  certificates whose common name isn't the name of their host; and `:add_remote`, to add a route.

  `ADS.Client` takes all this as `secure:`; this module has the parts, for tests and those who
  bring their own transport.
  """

  alias ADS.NetId

  @flags [
    response: 0x01,
    ams_allowed: 0x02,
    server_info: 0x04,
    own_file: 0x08,
    self_signed: 0x10,
    ip_address: 0x20,
    ignore_cn: 0x40,
    add_remote: 0x80
  ]

  @errors %{1 => :version, 2 => :cn_mismatch, 3 => :unknown_certificate, 4 => :unknown_user}

  # The suites the PLC takes for a pre-shared key: TLS 1.2, AES-CBC, with no Diffie-Hellman.
  @psk_suites ~w(TLS_PSK_WITH_AES_256_CBC_SHA384 TLS_PSK_WITH_AES_128_CBC_SHA256
                 TLS_PSK_WITH_AES_256_CBC_SHA TLS_PSK_WITH_AES_128_CBC_SHA)c

  # With certificates, TwinCAT 3.1 4026 takes only these, which OTP leaves out of its defaults:
  # they're offered after OTP's own.
  @certificate_suites ~w(TLS_DHE_RSA_WITH_AES_256_CBC_SHA256 TLS_DHE_RSA_WITH_AES_128_CBC_SHA256)c

  # Windows-1252 differs from Latin-1 in 0x80 to 0x9F.
  @cp1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }
  @from_unicode Map.new(@cp1252, fn {byte, char} -> {char, byte} end)

  @type flag ::
          :response
          | :ams_allowed
          | :server_info
          | :own_file
          | :self_signed
          | :ip_address
          | :ignore_cn
          | :add_remote

  @type connect_info :: %{
          flags: [flag],
          version: byte,
          error: nil | :version | :cn_mismatch | :unknown_certificate | :unknown_user | byte,
          net_id: ADS.NetId.t(),
          hostname: String.t(),
          credentials: {String.t(), String.t()} | nil
        }

  @doc """
  A TlsConnectInfo, with credentials to add a route, or nil. The host name is cut to 31 bytes.

      iex> info = ADS.Secure.connect_info([:self_signed], <<10, 0, 0, 7, 1, 1>>, "scada")
      iex> byte_size(info)
      64
      iex> {:ok, %{flags: [:self_signed], hostname: "scada"}, ""} = ADS.Secure.decode_connect_info(info)
  """
  @spec connect_info([flag], ADS.NetId.t(), String.t(), {String.t(), String.t()} | nil) :: binary
  def connect_info(flags, <<_::48>> = net_id, hostname, credentials \\ nil) do
    {user, password} =
      case credentials do
        nil -> {"", ""}
        {user, password} -> {ansi!(user), ansi!(password)}
      end

    if byte_size(user) > 255 or byte_size(password) > 255 or byte_size(user <> password) > 448,
      do: raise(ArgumentError, "a user name and password of at most 255 bytes each, 448 together")

    host = ansi!(hostname)
    host = binary_part(host, 0, min(byte_size(host), 31))

    <<64 + byte_size(user) + byte_size(password)::16-little, bits(flags)::16-little, 1, 0,
      net_id::binary-6, byte_size(user), byte_size(password), 0::144, host::binary,
      0::size((32 - byte_size(host)) * 8), user::binary, password::binary>>
  end

  defp bits(flags) do
    Enum.reduce(flags, 0, fn flag, bits ->
      case Keyword.fetch(@flags, flag) do
        {:ok, bit} -> Bitwise.bor(bits, bit)
        :error -> raise ArgumentError, "not a TlsConnectInfo flag: #{inspect(flag)}"
      end
    end)
  end

  @doc """
  The first TlsConnectInfo in the bytes: `{:ok, info, rest}`, `:more` for the start of one, or
  `:error` for one that can't be, longer than 512 bytes or shorter than 64.
  """
  @spec decode_connect_info(binary) :: {:ok, connect_info, binary} | :more | :error
  def decode_connect_info(<<length::16-little, _::binary>>) when length < 64 or length > 512,
    do: :error

  def decode_connect_info(<<length::16-little, _::binary>> = bytes)
      when byte_size(bytes) < length,
      do: :more

  def decode_connect_info(
        <<length::16-little, flags::16-little, version, error, net_id::binary-6, user_length,
          password_length, _reserved::binary-18, host::binary-32, rest::binary>>
      ) do
    case rest do
      <<user::binary-size(user_length), password::binary-size(password_length), rest::binary>>
      when 64 + user_length + password_length == length ->
        info = %{
          flags: for({flag, bit} <- @flags, Bitwise.band(flags, bit) != 0, do: flag),
          version: version,
          error: if(error == 0, do: nil, else: Map.get(@errors, error, error)),
          net_id: net_id,
          hostname: host |> :binary.split(<<0>>) |> hd() |> ansi(),
          credentials: if(length > 64, do: {ansi(user), ansi(password)})
        }

        {:ok, info, rest}

      _ ->
        :error
    end
  end

  def decode_connect_info(_partial), do: :more

  @doc """
  The pre-shared key of an identity and a password, as TwinCAT makes it: the SHA-256 of the
  identity in upper case followed by the password.
  """
  @spec psk_key(String.t(), String.t()) :: <<_::256>>
  def psk_key(identity, password),
    do: :crypto.hash(:sha256, ansi!(String.upcase(identity)) <> ansi!(password))

  @doc """
  A string in Windows-1252, as TwinCAT's routers write them; raises `ArgumentError` for one with
  characters it doesn't have.
  """
  @spec ansi!(String.t()) :: binary
  def ansi!(string) when is_binary(string) do
    if not String.valid?(string), do: raise(ArgumentError, "not UTF-8: #{inspect(string)}")

    for <<char::utf8 <- string>>, into: <<>> do
      cond do
        char < 0x80 or char in 0xA0..0xFF -> <<char>>
        Map.has_key?(@from_unicode, char) -> <<Map.fetch!(@from_unicode, char)>>
        true -> raise ArgumentError, "#{inspect(string)} has characters Windows-1252 doesn't"
      end
    end
  end

  @doc "A string from Windows-1252."
  @spec ansi(binary) :: String.t()
  def ansi(bytes),
    do: for(<<byte <- bytes>>, into: "", do: <<Map.get(@cp1252, byte, byte)::utf8>>)

  @doc """
  A certificate's fingerprint as Secure ADS compares them: the SHA-256 of its DER, as 64
  hexadecimal digits; the same as `ADS.Certificate.fingerprint/1`.
  """
  @spec fingerprint(binary) :: String.t()
  def fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der))

  @doc false
  # The options of secure: in ADS.Client, checked, and made ready to connect with.
  def config!(opts) do
    if not Keyword.keyword?(opts), do: raise(ArgumentError, "secure: must be a keyword list")

    known = [
      :psk,
      :cacerts,
      :cacertfile,
      :fingerprint,
      :cert,
      :certfile,
      :key,
      :keyfile,
      :add_route,
      :ignore_cn,
      :ip_address,
      :hostname,
      :ssl
    ]

    case Enum.uniq(Keyword.keys(opts)) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown secure: options: #{inspect(unknown)}"
    end

    mode = mode!(opts)
    flags = flags!(mode, opts)

    hostname =
      Keyword.get_lazy(opts, :hostname, fn -> elem(:inet.gethostname(), 1) |> to_string() end)

    _ = ansi!(hostname)

    %{
      mode: mode,
      ssl: ssl!(mode, opts),
      fingerprint: if(mode == :self_signed, do: fingerprint!(opts[:fingerprint])),
      add_route: add_route!(mode, opts[:add_route]),
      flags: flags,
      hostname: hostname
    }
  end

  defp mode!(opts) do
    case {Keyword.has_key?(opts, :psk),
          Keyword.has_key?(opts, :cacerts) or Keyword.has_key?(opts, :cacertfile),
          Keyword.has_key?(opts, :fingerprint)} do
      {true, false, false} ->
        :psk

      {false, true, false} ->
        :shared_ca

      {false, false, true} ->
        :self_signed

      _ ->
        raise ArgumentError,
              "secure: needs one of psk:, cacerts: (or cacertfile:) and fingerprint:"
    end
  end

  defp flags!(mode, opts) do
    own = for option <- [:ignore_cn, :ip_address], boolean!(opts, option), do: option
    if mode == :self_signed, do: [:self_signed | own], else: own
  end

  defp boolean!(opts, key) do
    case Keyword.get(opts, key, false) do
      value when is_boolean(value) -> value
      value -> raise ArgumentError, "#{key}: must be a boolean, got: #{inspect(value)}"
    end
  end

  defp ssl!(:psk, opts) do
    {identity, key} =
      case opts[:psk] do
        {identity, password} when is_binary(identity) and is_binary(password) ->
          {identity |> ansi!() |> :binary.bin_to_list(), psk_key(identity, password)}

        other ->
          raise ArgumentError, "psk: must be {identity, password}, got: #{inspect(other)}"
      end

    for name <- [:cacerts, :cacertfile, :cert, :certfile, :key, :keyfile, :add_route],
        Keyword.has_key?(opts, name),
        do: raise(ArgumentError, "#{name}: is for certificates, not psk:")

    [
      versions: [:"tlsv1.2"],
      ciphers: Enum.map(@psk_suites, &:ssl.str_to_suite/1),
      psk_identity: identity,
      user_lookup_fun: {fn :psk, _hint, key -> {:ok, key} end, key},
      verify: :verify_none,
      log_level: :none
    ] ++ extra!(opts)
  end

  defp ssl!(mode, opts) do
    own =
      cond do
        Keyword.has_key?(opts, :cert) and Keyword.has_key?(opts, :key) ->
          [cert: opts[:cert], key: key!(opts[:key])]

        Keyword.has_key?(opts, :certfile) and Keyword.has_key?(opts, :keyfile) ->
          [certfile: opts[:certfile], keyfile: opts[:keyfile]]

        true ->
          raise ArgumentError,
                "secure: needs a certificate of the client's own: cert: and key:, or certfile: and keyfile:"
      end

    verify =
      case mode do
        # The PLC's certificate is pinned by its fingerprint, checked after the handshake.
        :self_signed ->
          [verify: :verify_none]

        :shared_ca ->
          [verify: :verify_peer] ++
            Keyword.take(opts, [:cacerts, :cacertfile]) ++
            if(boolean!(opts, :ignore_cn),
              do: [server_name_indication: :disable],
              else: [
                customize_hostname_check: [
                  match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                ]
              ]
            )
      end

    extra = extra!(opts)
    [versions: [:"tlsv1.2"], log_level: :none] ++ ciphers(extra) ++ verify ++ own ++ extra
  end

  # OTP's own suites and then the PLC's, unless ssl: gives others.
  defp ciphers(extra) do
    if Keyword.has_key?(extra, :ciphers) do
      []
    else
      plc = Enum.map(@certificate_suites, &:ssl.str_to_suite/1)
      [ciphers: Enum.uniq(:ssl.cipher_suites(:default, :"tlsv1.2") ++ plc)]
    end
  end

  defp extra!(opts) do
    case Keyword.get(opts, :ssl, []) do
      ssl when is_list(ssl) -> ssl
      other -> raise ArgumentError, "ssl: must be a keyword list, got: #{inspect(other)}"
    end
  end

  # A key as :public_key decodes it, or as :ssl takes it, {type, der}.
  defp key!({type, der} = key) when is_atom(type) and is_binary(der), do: key

  defp key!(key) when is_tuple(key) and is_atom(elem(key, 0)),
    do: {elem(key, 0), :public_key.der_encode(elem(key, 0), key)}

  defp key!(key), do: raise(ArgumentError, "key: must be a private key, got: #{inspect(key)}")

  defp fingerprint!(:any), do: :any

  defp fingerprint!(hex) when is_binary(hex) do
    case hex |> String.replace([":", " ", "-"], "") |> Base.decode16(case: :mixed) do
      {:ok, <<_::256>> = fingerprint} -> fingerprint
      _ -> raise ArgumentError, "fingerprint: must be a SHA-256 in hex, got: #{inspect(hex)}"
    end
  end

  defp fingerprint!(other),
    do:
      raise(
        ArgumentError,
        "fingerprint: must be a SHA-256 in hex, or :any, got: #{inspect(other)}"
      )

  defp add_route!(_mode, nil), do: nil

  defp add_route!(:self_signed, {user, password} = login)
       when is_binary(user) and is_binary(password) do
    _ = connect_info([], <<0::48>>, "", login)
    login
  end

  defp add_route!(:self_signed, other),
    do: raise(ArgumentError, "add_route: must be {user, password}, got: #{inspect(other)}")

  defp add_route!(_mode, _login),
    do: raise(ArgumentError, "add_route: is for fingerprint:, self-signed certificates")

  @doc false
  # Connects, with the TLS handshake and the exchange of TlsConnectInfos, within timeout each.
  # The local NetId is the one given, or made from the address the connection has.
  def connect(host, port, config, local, timeout) do
    options = [
      :binary,
      packet: :raw,
      active: false,
      nodelay: true,
      keepalive: true,
      send_timeout: 5000,
      send_timeout_close: true
    ]

    case :ssl.connect(host, port, options ++ config.ssl, timeout) do
      {:ok, socket} ->
        case handshake(socket, config, local, timeout) do
          {:ok, info} ->
            {:ok, socket, info}

          {:error, reason} ->
            _ = :ssl.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handshake(socket, config, local, timeout) do
    flags = if config.add_route, do: config.flags ++ [:add_remote], else: config.flags

    with :ok <- pinned(socket, config.fingerprint),
         {:ok, local} <- local_net_id(socket, local),
         :ok <- :ssl.send(socket, connect_info(flags, local, config.hostname, config.add_route)),
         {:ok, answer, rest} <- answer(socket, <<>>, timeout) do
      cond do
        answer.error != nil -> {:error, {:secure_ads, answer.error}}
        :response not in answer.flags -> {:error, :invalid_connect_info}
        true -> {:ok, %{local: local, remote: answer.net_id, buffer: rest}}
      end
    end
  end

  defp pinned(_socket, nil), do: :ok
  defp pinned(_socket, :any), do: :ok

  defp pinned(socket, fingerprint) do
    case :ssl.peercert(socket) do
      {:ok, der} ->
        if :crypto.hash(:sha256, der) == fingerprint, do: :ok, else: {:error, :fingerprint}

      {:error, _} ->
        {:error, :fingerprint}
    end
  end

  defp local_net_id(_socket, <<_::48>> = local), do: {:ok, local}

  defp local_net_id(socket, nil) do
    case :ssl.sockname(socket) do
      {:ok, {{_, _, _, _} = ip, _port}} -> {:ok, NetId.from_ip(ip)}
      _ -> {:error, :local_net_id}
    end
  end

  defp answer(socket, buffer, timeout) do
    case decode_connect_info(buffer) do
      {:ok, answer, rest} ->
        {:ok, answer, rest}

      :more ->
        case :ssl.recv(socket, 0, timeout) do
          {:ok, data} -> answer(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :invalid_connect_info}
    end
  end
end
