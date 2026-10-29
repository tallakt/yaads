defmodule ADS.Certificate do
  @moduledoc """
  X.509 certificates for Secure ADS, as DER binaries.

  With self-signed certificates, each side makes its own, and knows the other's by its
  fingerprint. The client's is made once and kept, since the PLC remembers it when the route is
  added:

      {cert, key} = ADS.Certificate.self_signed("scada")
      :ok = ADS.Certificate.write("scada.pem", cert)
      :ok = ADS.Certificate.write_key("scada.key", key)
      ADS.Certificate.fingerprint(cert)

  With a CA, the certificates come from it, and these functions read them.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(
    :tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(:validity, :Validity, Record.extract(:Validity, from_lib: @hrl))
  Record.defrecordp(:extension, :Extension, Record.extract(:Extension, from_lib: @hrl))

  @sha256_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @rsa {1, 2, 840, 113_549, 1, 1, 1}
  @common_name {2, 5, 4, 3}
  @subject_alt_name {2, 5, 29, 17}
  @key_usage {2, 5, 29, 15}
  @ext_key_usage {2, 5, 29, 37}
  @basic_constraints {2, 5, 29, 19}
  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}

  @type t :: binary
  @type private_key :: tuple

  @doc """
  Makes a self-signed certificate and its private key, with a common name: the name of the client,
  as the PLC compares it with the route unless told to ignore it.

    * `:hostnames` - DNS names and IP addresses for its subject alternative name (default the
      common name)
    * `:days` - how long it's valid (default 3650)
    * `:key_size` - RSA key bits (default 2048)
  """
  @spec self_signed(String.t(), keyword) :: {t, private_key}
  def self_signed(name, opts \\ []) do
    key = :public_key.generate_key({:rsa, Keyword.get(opts, :key_size, 2048), 65_537})
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = key
    now = DateTime.utc_now()
    subject = {:rdnSequence, [[{:AttributeTypeAndValue, @common_name, {:utf8String, name}}]]}

    alt_names =
      for host <- Keyword.get(opts, :hostnames, [name]) do
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, ip} -> {:iPAddress, ip |> Tuple.to_list() |> :binary.list_to_bin()}
          {:error, _} -> {:dNSName, String.to_charlist(host)}
        end
      end

    tbs =
      tbs_certificate(
        version: :v3,
        serialNumber: :binary.decode_unsigned(:crypto.strong_rand_bytes(16)),
        signature: {:SignatureAlgorithm, @sha256_rsa, no_parameters()},
        issuer: subject,
        validity:
          validity(
            notBefore: time(DateTime.add(now, -1, :day)),
            notAfter: time(DateTime.add(now, Keyword.get(opts, :days, 3650), :day))
          ),
        subject: subject,
        subjectPublicKeyInfo:
          key_info(
            algorithm: {:PublicKeyAlgorithm, @rsa, no_parameters()},
            subjectPublicKey: {:RSAPublicKey, modulus, exponent}
          ),
        extensions: [
          extension(extnID: @subject_alt_name, critical: false, extnValue: alt_names),
          extension(
            extnID: @basic_constraints,
            critical: true,
            extnValue: {:BasicConstraints, false, :asn1_NOVALUE}
          ),
          extension(
            extnID: @key_usage,
            critical: true,
            extnValue: [:digitalSignature, :keyEncipherment]
          ),
          extension(
            extnID: @ext_key_usage,
            critical: false,
            extnValue: [@server_auth, @client_auth]
          )
        ]
      )

    {:public_key.pkix_sign(tbs, key), key}
  end

  # RSA's algorithm identifiers have NULL parameters, which OTP 28 writes itself when they're left
  # out, and before it had to be given.
  defp no_parameters do
    if :otp_release |> :erlang.system_info() |> List.to_integer() >= 28,
      do: :asn1_NOVALUE,
      else: :NULL
  end

  # UTCTime until 2049, GeneralizedTime after (RFC 5280, 4.1.2.5).
  defp time(%DateTime{year: year} = t) when year < 2050,
    do: {:utcTime, Calendar.strftime(t, "%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp time(t), do: {:generalTime, Calendar.strftime(t, "%Y%m%d%H%M%SZ") |> String.to_charlist()}

  @doc """
  A certificate's fingerprint: the SHA-256 of its DER, as 64 hexadecimal digits, as TwinCAT shows
  its own in the About TwinCAT dialog.
  """
  @spec fingerprint(t) :: String.t()
  defdelegate fingerprint(der), to: ADS.Secure

  @doc "Reads a certificate from a DER or PEM file."
  @spec read(Path.t()) :: t
  def read(path) do
    data = File.read!(path)

    case :public_key.pem_decode(data) do
      [{:Certificate, der, _} | _] -> der
      _ -> data
    end
  end

  @doc "Reads a private key from a PEM file."
  @spec read_key(Path.t()) :: private_key
  def read_key(path) do
    [entry | _] = path |> File.read!() |> :public_key.pem_decode()
    :public_key.pem_entry_decode(entry)
  end

  @doc "Writes a certificate as DER, or PEM if the path ends in `.pem`."
  @spec write(Path.t(), t) :: :ok | {:error, File.posix()}
  def write(path, der) do
    data =
      if Path.extname(path) == ".pem",
        do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]),
        else: der

    File.write(path, data)
  end

  @doc "Writes an RSA private key as PEM."
  @spec write_key(Path.t(), private_key) :: :ok | {:error, File.posix()}
  def write_key(path, key),
    do:
      File.write(
        path,
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      )
end
