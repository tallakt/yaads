defmodule ADS.SecureTest do
  use ExUnit.Case, async: true

  alias ADS.{Certificate, Client, Secure}
  alias ADS.Test.FakePLC

  @rsa [key: {:rsa, 2048, 65_537}, digest: :sha256]
  @san {:Extension, {2, 5, 29, 17}, false, [{:iPAddress, <<127, 0, 0, 1>>}]}
  @psk_suites ~w(TLS_PSK_WITH_AES_256_CBC_SHA384 TLS_PSK_WITH_AES_128_CBC_SHA256)c

  # RSA keys take a while to make, so each is made once.
  setup_all do
    pki =
      :public_key.pkix_test_data(%{
        server_chain: %{root: @rsa, intermediates: [], peer: @rsa ++ [extensions: [@san]]},
        client_chain: %{root: @rsa, intermediates: [], peer: @rsa}
      })

    %{
      pki: pki,
      plc_self: Certificate.self_signed("plc"),
      client_self: Certificate.self_signed("scada")
    }
  end

  test "a TlsConnectInfo: 64 bytes, as laid out, and the credentials after" do
    info =
      Secure.connect_info(
        [:self_signed, :add_remote],
        <<10, 0, 0, 7, 1, 1>>,
        "scada",
        {"Administrator", "1"}
      )

    assert <<78::16-little, 0x90::16-little, 1, 0, 10, 0, 0, 7, 1, 1, 13, 1, reserved::binary-18,
             host::binary-32, "Administrator", "1">> = info

    assert reserved == :binary.copy(<<0>>, 18)
    assert host == "scada" <> :binary.copy(<<0>>, 27)

    assert {:ok, decoded, ""} = Secure.decode_connect_info(info)
    assert decoded.flags == [:self_signed, :add_remote]
    assert decoded.credentials == {"Administrator", "1"}
    assert decoded.net_id == <<10, 0, 0, 7, 1, 1>>
    assert decoded.error == nil
  end

  test "an answer's error, and what isn't a TlsConnectInfo" do
    <<head::binary-5, _error, tail::binary>> =
      Secure.connect_info([:response], <<1, 2, 3, 4, 5, 6>>, "plc")

    assert {:ok, %{error: :unknown_user, flags: [:response]}, ""} =
             Secure.decode_connect_info(<<head::binary, 4, tail::binary>>)

    assert {:ok, %{error: 9}, ""} = Secure.decode_connect_info(<<head::binary, 9, tail::binary>>)
    assert Secure.decode_connect_info(binary_part(head <> tail, 0, 30)) == :more
    assert Secure.decode_connect_info(<<10::16-little, 0::64>>) == :error
    assert Secure.decode_connect_info(<<600::16-little, 0::64>>) == :error
    # credentials whose lengths disagree with the total
    <<_::16, rest::binary-10, _u, _p, more::binary>> = Secure.connect_info([], <<0::48>>, "x")

    assert Secure.decode_connect_info(<<64::16-little, rest::binary, 1, 0, more::binary>> <> "u") ==
             :error
  end

  test "host names cut to 31 bytes, credentials of at most 255 bytes each and 448 together" do
    assert {:ok, %{hostname: hostname}, ""} =
             Secure.decode_connect_info(
               Secure.connect_info([], <<0::48>>, String.duplicate("h", 40))
             )

    assert hostname == String.duplicate("h", 31)

    assert_raise ArgumentError, fn ->
      Secure.connect_info([], <<0::48>>, "x", {String.duplicate("u", 256), ""})
    end

    assert_raise ArgumentError, fn ->
      Secure.connect_info(
        [],
        <<0::48>>,
        "x",
        {String.duplicate("u", 250), String.duplicate("p", 250)}
      )
    end

    assert_raise ArgumentError, fn -> Secure.connect_info([:flying], <<0::48>>, "x") end
  end

  test "the pre-shared key: the SHA-256 of the identity in upper case and the password" do
    assert Secure.psk_key("MY_IDENTITY", "MySecret") ==
             :crypto.hash(:sha256, "MY_IDENTITYMySecret")

    assert Secure.psk_key("my_identity", "MySecret") == Secure.psk_key("MY_IDENTITY", "MySecret")
    refute Secure.psk_key("MY_IDENTITY", "mysecret") == Secure.psk_key("MY_IDENTITY", "MySecret")
  end

  test "strings in Windows-1252" do
    assert Secure.ansi!("Grüße €") == <<"Gr", 0xFC, 0xDF, "e ", 0x80>>
    assert Secure.ansi(<<"Gr", 0xFC, 0xDF, "e ", 0x80, 0x9F>>) == "Grüße €Ÿ"
    assert_raise ArgumentError, fn -> Secure.ansi!("Ω") end
    assert_raise ArgumentError, fn -> Secure.ansi!(<<0xFF>>) end
  end

  test "fingerprints, as TwinCAT shows them", %{client_self: {cert, _key}} do
    fingerprint = Certificate.fingerprint(cert)
    assert fingerprint == Base.encode16(:crypto.hash(:sha256, cert))
    assert byte_size(fingerprint) == 64
  end

  # With certificates, the fake takes only the suites TwinCAT 3.1 4026 does, which OTP's defaults
  # leave out.
  @twincat_suites ~w(TLS_DHE_RSA_WITH_AES_256_CBC_SHA256 TLS_DHE_RSA_WITH_AES_128_CBC_SHA256)c

  defp secure_plc(ssl) do
    ssl =
      if Keyword.has_key?(ssl, :ciphers),
        do: ssl,
        else: [ciphers: Enum.map(@twincat_suites, &:ssl.str_to_suite/1)] ++ ssl

    start_supervised!({FakePLC, secure: %{ssl: ssl}}, id: make_ref())
  end

  defp client(plc, secure, opts \\ []) do
    opts =
      Keyword.merge(
        [
          host: "127.0.0.1",
          port: FakePLC.port(plc),
          secure: secure,
          timeout: 1000,
          backoff: {20, 50}
        ],
        opts
      )

    start_supervised!({Client, opts}, id: make_ref())
  end

  defp eventually(fun, tries \\ 300) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else: Process.sleep(10) && eventually(fun, tries - 1)
  end

  test "certificates from a CA both sides trust; the PLC's NetId from its answer", %{pki: pki} do
    plc = secure_plc(pki.server_config ++ [verify: :verify_peer, fail_if_no_peer_cert: true])

    secure = [
      cacerts: pki.client_config[:cacerts],
      cert: pki.client_config[:cert],
      key: pki.client_config[:key],
      hostname: "scada"
    ]

    client = client(plc, secure, local_net_id: "10.0.0.7.1.1")

    assert Client.read_state(client) == {:ok, %{ads_state: :run, device_state: 0}}
    :ok = Client.write(client, "MAIN.nSpeed", 1500)
    assert Client.read(client, "MAIN.nSpeed") == {:ok, 1500}
    assert {:ok, ref} = Client.subscribe(client, "MAIN.nSpeed")
    assert_receive {Client, ^ref, {:value, "MAIN.nSpeed", 1500, _}}
    assert %{remote: {"5.36.69.176.1.1", 851}} = Client.info(client)

    assert [%{flags: [], net_id: <<10, 0, 0, 7, 1, 1>>, hostname: "scada", credentials: nil}] =
             FakePLC.connect_infos(plc)
  end

  test "a PLC whose certificate isn't from the CA isn't talked to", %{
    pki: pki,
    plc_self: {cert, key}
  } do
    plc =
      secure_plc(cert: cert, key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)})

    secure = [
      cacerts: pki.client_config[:cacerts],
      cert: pki.client_config[:cert],
      key: pki.client_config[:key]
    ]

    client = client(plc, secure)
    eventually(fn -> match?({:disconnected, {:tls_alert, _}}, Client.status(client)) end)
    assert Client.read_state(client) == {:error, :closed}
  end

  test "a pre-shared key, as the PLC's StaticRoutes.xml has it" do
    keys = %{"SCADA" => Secure.psk_key("scada", "secret")}

    lookup = fn :psk, identity, keys ->
      Map.fetch(keys, identity |> to_string() |> String.upcase())
    end

    plc =
      secure_plc(
        versions: [:"tlsv1.2"],
        ciphers: Enum.map(@psk_suites, &:ssl.str_to_suite/1),
        user_lookup_fun: {lookup, keys}
      )

    client = client(plc, psk: {"scada", "secret"}, hostname: "scada")
    assert Client.read_device_info(client) == {:ok, %{name: "Plc30 App", version: {3, 1, 4026}}}
    assert [%{flags: [], credentials: nil}] = FakePLC.connect_infos(plc)

    wrong = client(plc, psk: {"scada", "guess"})
    eventually(fn -> match?({:disconnected, _}, Client.status(wrong)) end)
    assert Client.read_state(wrong) == {:error, :closed}
  end

  test "self-signed: the PLC's certificate pinned by its fingerprint, and a route added once",
       %{plc_self: {plc_cert, plc_key}, client_self: {cert, key}} do
    trust_any = {fn _cert, _event, state -> {:valid, state} end, nil}

    plc =
      secure_plc(
        cert: plc_cert,
        key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, plc_key)},
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        cacerts: [plc_cert],
        verify_fun: trust_any
      )

    secure = [
      fingerprint: Certificate.fingerprint(plc_cert),
      cert: cert,
      key: key,
      add_route: {"Administrator", "1"},
      ip_address: true,
      ignore_cn: true
    ]

    client = client(plc, secure)
    assert {:ok, _} = Client.read_state(client)

    assert [
             %{
               flags: [:self_signed, :ip_address, :ignore_cn, :add_remote],
               credentials: {"Administrator", "1"}
             }
           ] = FakePLC.connect_infos(plc)

    # the route is there now: the next connection doesn't add it again
    :ok = FakePLC.drop_connections(plc)
    eventually(fn -> length(FakePLC.connect_infos(plc)) == 2 end)

    assert [_, %{flags: [:self_signed, :ip_address, :ignore_cn], credentials: nil}] =
             FakePLC.connect_infos(plc)

    # a fingerprint written with colons, in lower case
    pinned =
      plc_cert
      |> Certificate.fingerprint()
      |> String.downcase()
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)

    other = client(plc, fingerprint: pinned, cert: cert, key: key)
    assert {:ok, _} = Client.read_state(other)
  end

  test "self-signed: a PLC with another certificate, or that refuses the user, isn't talked to",
       %{plc_self: {plc_cert, plc_key}, client_self: {cert, key}} do
    trust_any = {fn _cert, _event, state -> {:valid, state} end, nil}

    plc =
      secure_plc(
        cert: plc_cert,
        key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, plc_key)},
        verify: :verify_peer,
        cacerts: [plc_cert],
        verify_fun: trust_any
      )

    pinned = client(plc, fingerprint: Certificate.fingerprint(cert), cert: cert, key: key)
    eventually(fn -> Client.status(pinned) == {:disconnected, :fingerprint} end)

    refused =
      client(plc,
        fingerprint: Certificate.fingerprint(plc_cert),
        cert: cert,
        key: key,
        add_route: {"Administrator", "wrong"}
      )

    eventually(fn -> Client.status(refused) == {:disconnected, {:secure_ads, :unknown_user}} end)

    anyone = client(plc, fingerprint: :any, cert: cert, key: key)
    assert {:ok, _} = Client.read_state(anyone)
  end

  test "secure options that don't make sense raise", %{client_self: {cert, key}} do
    for secure <- [
          [],
          [psk: {"a", "b"}, fingerprint: :any],
          [psk: "secret"],
          [psk: {"a", "b"}, cert: cert],
          [cacertfile: "ca.pem"],
          [fingerprint: "abc", cert: cert, key: key],
          [fingerprint: 42, cert: cert, key: key],
          [fingerprint: :any, cert: cert, key: :nope],
          [cacertfile: "ca.pem", certfile: "c.pem", keyfile: "c.key", add_route: {"a", "b"}],
          [fingerprint: :any, cert: cert, key: key, add_route: "admin"],
          [fingerprint: :any, cert: cert, key: key, ignore_cn: "yes"],
          [fingerprint: :any, cert: cert, key: key, ssl: :nope],
          [fingerprint: :any, cert: cert, key: key, hostname: "Ω"],
          [fingerprint: :any, cert: cert, key: key, flying: true],
          :nope
        ] do
      assert_raise ArgumentError, fn -> Client.start_link(host: "plc", secure: secure) end
    end
  end

  test "certificates to and from files", %{client_self: {cert, key}} do
    dir = Path.join(System.tmp_dir!(), "yaads-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- ["scada.pem", "scada.der"] do
      path = Path.join(dir, name)
      :ok = Certificate.write(path, cert)
      assert Certificate.read(path) == cert
    end

    path = Path.join(dir, "scada.key")
    :ok = Certificate.write_key(path, key)
    assert Certificate.read_key(path) == key

    assert {:ok, _} = :public_key.pkix_path_validation(cert, [cert], [])

    {cert, _key} =
      Certificate.self_signed("plc1",
        hostnames: ["plc1.local", "10.0.0.5"],
        days: 1,
        key_size: 1024
      )

    assert :public_key.pkix_verify_hostname(cert, dns_id: ~c"plc1.local")
    assert :public_key.pkix_verify_hostname(cert, ip: {10, 0, 0, 5})
  end
end
