defmodule ADS.Command do
  @moduledoc """
  The nine ADS commands: the data of their requests and of the responses to them, inside AMS
  packets (see `ADS.AMS`). All numbers are little-endian.

  A request is a tuple, and its result is a value:

  | Request | Command | Result |
  |---|---|---|
  | `:read_device_info` | 1 | `{:ok, %{name: name, version: {major, minor, build}}}` |
  | `{:read, index_group, index_offset, length}` | 2 | `{:ok, binary}` |
  | `{:write, index_group, index_offset, binary}` | 3 | `:ok` |
  | `:read_state` | 4 | `{:ok, %{ads_state: state, device_state: integer}}` |
  | `{:write_control, ads_state, device_state, binary}` | 5 | `:ok` |
  | `{:add_notification, index_group, index_offset, length, mode, max_delay, cycle_time}` | 6 | `{:ok, handle}` |
  | `{:delete_notification, handle}` | 7 | `:ok` |
  | `{:read_write, index_group, index_offset, read_length, binary}` | 9 | `{:ok, binary}` |

  Command 8, the device notification, goes the other way: a device sends it, unasked and
  unanswered, with the samples of the notifications a client added (`decode_notification/1`).

  The mode of a notification is `:cyclic`, every cycle time, or `:on_change`, checked every cycle
  time; Beckhoff's documentation calls them ADSTRANS_SERVERCYCLE (3) and ADSTRANS_SERVERONCHA (4).
  Its max delay and cycle time are in units of 100 ns on the wire, as in the ADS-DLL's
  AdsNotificationAttrib and its samples, where a cycle time of 10000000 is a second; the ADS spec's
  table of the command says 1 ms, which the TwinCAT devices don't follow.

      iex> ADS.Command.encode_request({:read, 0x4020, 0, 4})
      {2, <<0x20, 0x40, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0>>}
      iex> ADS.Command.decode_response({:read, 0x4020, 0, 4}, <<0::32, 4::32-little, 42::32-little>>)
      {:ok, <<42, 0, 0, 0>>}
      iex> ADS.Command.decode_response({:read, 0xF005, 7, 4}, <<0x10, 0x07, 0, 0>>)
      {:error, :device_symbol_not_found}
  """

  @type index_group :: ADS.index_group()
  @type index_offset :: ADS.index_offset()
  @type mode :: :cyclic | :on_change | 0..0xFFFFFFFF

  @type request ::
          :read_device_info
          | {:read, index_group, index_offset, 0..0xFFFFFFFF}
          | {:write, index_group, index_offset, binary}
          | :read_state
          | {:write_control, ADS.state(), 0..65535, binary}
          | {:add_notification, index_group, index_offset, 0..0xFFFFFFFF, mode, 0..0xFFFFFFFF,
             0..0xFFFFFFFF}
          | {:delete_notification, 0..0xFFFFFFFF}
          | {:read_write, index_group, index_offset, 0..0xFFFFFFFF, binary}

  @type result :: :ok | {:ok, term} | {:error, ADS.error()}

  @typedoc "The samples of a device notification: a timestamp, and each notification's data."
  @type stamp :: {DateTime.t() | nil, [{handle :: 0..0xFFFFFFFF, binary}]}

  # 100 ns intervals between 1601-01-01, where FILETIME starts, and 1970-01-01.
  @epoch 116_444_736_000_000_000

  @modes %{cyclic: 3, on_change: 4}

  # An integer in the range, as `in` checks.
  defguardp u32(n) when n in 0..0xFFFFFFFF

  @doc "The command id of a request: 1 to 9, as in the AMS header."
  @spec command_id(request | :device_notification) :: 1..9
  def command_id(:read_device_info), do: 1
  def command_id({:read, _, _, _}), do: 2
  def command_id({:write, _, _, _}), do: 3
  def command_id(:read_state), do: 4
  def command_id({:write_control, _, _, _}), do: 5
  def command_id({:add_notification, _, _, _, _, _, _}), do: 6
  def command_id({:delete_notification, _}), do: 7
  def command_id(:device_notification), do: 8
  def command_id({:read_write, _, _, _, _}), do: 9

  @doc """
  The command id and data of a request. Raises `ArgumentError` for one that doesn't fit the
  protocol, such as an index group past 32 bits.
  """
  @spec encode_request(request) :: {1..9, binary}
  def encode_request(request), do: {command_id!(request), data(request)}

  defp command_id!(request) do
    command_id(request)
  rescue
    FunctionClauseError ->
      reraise ArgumentError, [message: "not an ADS request: #{inspect(request)}"], __STACKTRACE__
  end

  defp data(:read_device_info), do: <<>>
  defp data(:read_state), do: <<>>

  defp data({:read, group, offset, length}) do
    check!(u32(group) and u32(offset) and u32(length), {:read, group, offset, length})
    <<group::32-little, offset::32-little, length::32-little>>
  end

  defp data({:write, group, offset, data} = request) do
    check!(u32(group) and u32(offset) and is_binary(data), request)
    <<group::32-little, offset::32-little, byte_size(data)::32-little, data::binary>>
  end

  defp data({:write_control, state, device_state, data} = request) do
    check!(device_state in 0..65535 and is_binary(data), request)

    <<ADS.state_code(state)::16-little, device_state::16-little, byte_size(data)::32-little,
      data::binary>>
  end

  defp data({:add_notification, group, offset, length, mode, max_delay, cycle_time} = request) do
    mode = Map.get(@modes, mode, mode)

    check!(
      u32(group) and u32(offset) and u32(length) and u32(mode) and u32(max_delay) and
        u32(cycle_time),
      request
    )

    <<group::32-little, offset::32-little, length::32-little, mode::32-little,
      max_delay::32-little, cycle_time::32-little, 0::128>>
  end

  defp data({:delete_notification, handle} = request) do
    check!(u32(handle), request)
    <<handle::32-little>>
  end

  defp data({:read_write, group, offset, read_length, data} = request) do
    check!(u32(group) and u32(offset) and u32(read_length) and is_binary(data), request)

    <<group::32-little, offset::32-little, read_length::32-little, byte_size(data)::32-little,
      data::binary>>
  end

  defp check!(true, _request), do: :ok

  defp check!(false, request),
    do: raise(ArgumentError, "an ADS request with numbers of 32 bits, got: #{inspect(request)}")

  @doc """
  The result of a request from the data of its response. A result other than 0 is the error of
  that return code; a response that doesn't fit the request, such as a read that gives more than
  asked for, is `{:error, {:invalid_response, data}}`.
  """
  @spec decode_response(request, binary) :: result
  def decode_response(_request, <<result::32-little, _rest::binary>>) when result != 0,
    do: {:error, ADS.ReturnCode.name(result)}

  def decode_response(
        :read_device_info,
        <<0::32, major, minor, build::16-little, name::binary-16>>
      ),
      do: {:ok, %{name: cstring(name), version: {major, minor, build}}}

  def decode_response({:read, _, _, max}, <<0::32, length::32-little, data::binary>>)
      when byte_size(data) == length and length <= max,
      do: {:ok, data}

  def decode_response({:read_write, _, _, max, _}, <<0::32, length::32-little, data::binary>>)
      when byte_size(data) == length and length <= max,
      do: {:ok, data}

  def decode_response(:read_state, <<0::32, state::16-little, device_state::16-little>>),
    do: {:ok, %{ads_state: ADS.state_name(state), device_state: device_state}}

  def decode_response({:add_notification, _, _, _, _, _, _}, <<0::32, handle::32-little>>),
    do: {:ok, handle}

  def decode_response({command, _, _, _}, <<0::32>>) when command in [:write, :write_control],
    do: :ok

  def decode_response({:delete_notification, _}, <<0::32>>), do: :ok
  def decode_response(_request, data), do: {:error, {:invalid_response, data}}

  # A device name: 16 bytes, up to the first zero, in Latin-1.
  defp cstring(bytes) do
    [string | _] = :binary.split(bytes, <<0>>)
    :unicode.characters_to_binary(string, :latin1)
  end

  @doc """
  The stamps of a device notification, each with the samples taken at its time, or `:error` for
  data that isn't one. A sample of no data says that its handle is no longer valid: the device
  sends one such, once, when its variable goes away, as after an online change.

  The timestamps are FILETIMEs, in UTC, here a `DateTime` with microseconds, the last digit of its
  100 ns dropped; or nil for one past what `DateTime` can hold.
  """
  @spec decode_notification(binary) :: {:ok, [stamp]} | :error
  def decode_notification(<<_length::32-little, count::32-little, rest::binary>>),
    do: stamps(rest, count, [])

  def decode_notification(_data), do: :error

  defp stamps(_rest, 0, stamps), do: {:ok, Enum.reverse(stamps)}

  defp stamps(<<time::64-little, count::32-little, rest::binary>>, n, stamps) do
    case samples(rest, count, []) do
      {:ok, samples, rest} -> stamps(rest, n - 1, [{from_filetime(time), samples} | stamps])
      :error -> :error
    end
  end

  defp stamps(_rest, _n, _stamps), do: :error

  defp samples(rest, 0, samples), do: {:ok, Enum.reverse(samples), rest}

  defp samples(
         <<handle::32-little, size::32-little, data::binary-size(size), rest::binary>>,
         n,
         s
       ),
       do: samples(rest, n - 1, [{handle, data} | s])

  defp samples(_rest, _n, _samples), do: :error

  @doc """
  A device notification's data, from its stamps: the inverse of `decode_notification/1`, for
  tests and for those who play a device.
  """
  @spec encode_notification([stamp]) :: binary
  def encode_notification(stamps) do
    body =
      for {time, samples} <- stamps, into: <<length(stamps)::32-little>> do
        for {handle, data} <- samples,
            into: <<to_filetime(time)::64-little, length(samples)::32-little>>,
            do: <<handle::32-little, byte_size(data)::32-little, data::binary>>
      end

    <<byte_size(body)::32-little, body::binary>>
  end

  @doc """
  A FILETIME, 100 ns intervals since 1601-01-01 in UTC, as a `DateTime`, or nil for one it can't
  hold.

      iex> ADS.Command.from_filetime(116_444_736_000_000_000)
      ~U[1970-01-01 00:00:00.000000Z]
  """
  @spec from_filetime(non_neg_integer) :: DateTime.t() | nil
  def from_filetime(time) do
    case DateTime.from_unix(div(time - @epoch, 10), :microsecond) do
      {:ok, datetime} -> datetime
      {:error, _} -> nil
    end
  end

  @doc "A `DateTime` as a FILETIME."
  @spec to_filetime(DateTime.t() | nil) :: non_neg_integer
  def to_filetime(nil), do: 0
  def to_filetime(datetime), do: DateTime.to_unix(datetime, :microsecond) * 10 + @epoch
end
