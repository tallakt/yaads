defmodule ADS.AMS do
  @moduledoc """
  AMS packets, which carry every ADS command and response: a 32-byte AMS header with the addresses
  of both ends, the command, flags, the length of the data, an error code and an invoke id, then
  the data. All numbers are little-endian.

  Over TCP, to port 48898, each packet has the 6-byte AMS/TCP header in front: two reserved bytes,
  which must be 0, and the length of the packet. Inside Secure ADS's TLS, on port 8016, packets go
  without it, as the AMS header holds their length too. `encode/2` and `decode/3` take `:tcp` or
  `:tls` for the one or the other.

      iex> packet = %ADS.AMS{target: <<5, 36, 69, 176, 1, 1>>, target_port: 851,
      ...>   source: <<10, 0, 0, 7, 1, 1>>, source_port: 32905, command: 4, invoke_id: 1}
      iex> frame = ADS.AMS.encode(packet)
      iex> byte_size(frame)
      38
      iex> {:ok, ^packet, ""} = ADS.AMS.decode(frame)

  A request has state flags `0x0004`, an ADS command, and a response `0x0005`; the client picks
  the invoke id, and the device copies it into its response.
  """

  @request 0x0004
  @response 0x0005

  # A response to a read of 16 MB, as the client takes by default.
  @max_data 16 * 1024 * 1024

  defstruct target: <<0::48>>,
            target_port: 0,
            source: <<0::48>>,
            source_port: 0,
            command: 0,
            state_flags: @request,
            error_code: 0,
            invoke_id: 0,
            data: <<>>

  @type t :: %__MODULE__{
          target: ADS.NetId.t(),
          target_port: ADS.ams_port(),
          source: ADS.NetId.t(),
          source_port: ADS.ams_port(),
          command: 0..65535,
          state_flags: 0..65535,
          error_code: 0..0xFFFFFFFF,
          invoke_id: 0..0xFFFFFFFF,
          data: binary
        }

  @typedoc "With the AMS/TCP header in front, as over TCP, or without, as inside Secure ADS."
  @type framing :: :tcp | :tls

  @doc "The state flags of a request, `0x0004`."
  @spec request_flags() :: 0x0004
  def request_flags, do: @request

  @doc "The state flags of a response, `0x0005`."
  @spec response_flags() :: 0x0005
  def response_flags, do: @response

  @doc "Whether a packet is a response, by the lowest bit of its state flags."
  @spec response?(t) :: boolean
  def response?(%__MODULE__{state_flags: flags}), do: Bitwise.band(flags, 1) == 1

  @doc "A packet as bytes to send."
  @spec encode(t, framing) :: binary
  def encode(%__MODULE__{} = packet, framing \\ :tcp) do
    data = packet.data

    ams =
      <<packet.target::binary-6, packet.target_port::16-little, packet.source::binary-6,
        packet.source_port::16-little, packet.command::16-little, packet.state_flags::16-little,
        byte_size(data)::32-little, packet.error_code::32-little, packet.invoke_id::32-little,
        data::binary>>

    case framing do
      :tcp -> <<0::16, byte_size(ams)::32-little, ams::binary>>
      :tls -> ams
    end
  end

  @doc """
  The first packet in what has come over a connection so far:

    * `{:ok, packet, rest}` for a whole packet
    * `:more` for the start of one
    * `{:discard, rest}` for a frame that isn't an AMS packet, with reserved bytes other than 0 in
      its AMS/TCP header, or a length that doesn't agree with its AMS header's
    * `{:error, :invalid_length}` for one longer than `max_data` bytes of data allows, or too short
      for an AMS header, after which there's no telling where the next starts

  The start of a packet, and one too short:

      iex> ADS.AMS.decode(<<0, 0, 32, 0, 0, 0, 1, 2, 3>>)
      :more
      iex> ADS.AMS.decode(<<0, 0, 12, 0, 0, 0>> <> <<0::96>>)
      {:error, :invalid_length}
  """
  @spec decode(binary, framing, non_neg_integer) ::
          {:ok, t, binary} | {:discard, binary} | :more | {:error, :invalid_length}
  def decode(buffer, framing \\ :tcp, max_data \\ @max_data)

  def decode(<<reserved::16-little, length::32-little, rest::binary>>, :tcp, max_data) do
    cond do
      length > max_data + 32 or (reserved == 0 and length < 32) ->
        {:error, :invalid_length}

      byte_size(rest) < length ->
        :more

      true ->
        <<frame::binary-size(length), rest::binary>> = rest
        frame(reserved, frame, rest)
    end
  end

  def decode(<<header::binary-32, rest::binary>>, :tls, max_data) do
    <<_::binary-20, length::32-little, _::binary-8>> = header

    cond do
      length > max_data ->
        {:error, :invalid_length}

      byte_size(rest) < length ->
        :more

      true ->
        <<data::binary-size(length), rest::binary>> = rest
        {:ok, packet} = packet(header, data)
        {:ok, packet, rest}
    end
  end

  def decode(_partial, framing, _max_data) when framing in [:tcp, :tls], do: :more

  defp frame(0, <<header::binary-32, data::binary>>, rest) do
    case packet(header, data) do
      {:ok, packet} -> {:ok, packet, rest}
      :error -> {:discard, rest}
    end
  end

  defp frame(_other_protocol, _frame, rest), do: {:discard, rest}

  defp packet(header, data) do
    <<target::binary-6, target_port::16-little, source::binary-6, source_port::16-little,
      command::16-little, flags::16-little, length::32-little, error::32-little,
      invoke::32-little>> = header

    if length == byte_size(data) do
      {:ok,
       %__MODULE__{
         target: target,
         target_port: target_port,
         source: source,
         source_port: source_port,
         command: command,
         state_flags: flags,
         error_code: error,
         invoke_id: invoke,
         data: data
       }}
    else
      :error
    end
  end
end
