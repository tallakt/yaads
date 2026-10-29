defmodule ADS.Sum do
  @moduledoc """
  Sum commands: many reads, writes, or read-writes in one ADS read-write, to an index group of the
  system services with the number of them as index offset.

  | Index group | Write data | Read data |
  |---|---|---|
  | `0xF080`, reads | each `{index_group, index_offset, length}` | the return codes, then the data of each |
  | `0xF081`, writes | each `{index_group, index_offset, length}`, then the data of each | the return codes |
  | `0xF082`, read-writes | each `{index_group, index_offset, read_length, write_length}`, then the data written | each return code and length read, then the data read |

  Each part of the request and of the response is the same 32-bit little-endian numbers as the
  single commands'. Beckhoff recommends at most 500 at a time (`max/0`): a device does them all
  before its next cycle.

  The results come in the order asked, each `{:ok, data}` or `:ok`, or `{:error, name}` with its
  return code:

      iex> reads = [{0x4020, 0, 2}, {0x4020, 8, 1}]
      iex> {:read_write, 0xF080, 2, 11, _headers} = ADS.Sum.read(reads)
      iex> ADS.Sum.decode_read(reads, <<0::32, 0x703::32-little, 7, 0, 0>>)
      {:ok, [{:ok, <<7, 0>>}, {:error, :device_invalid_offset}]}
  """

  @read 0xF080
  @write 0xF081
  @read_write 0xF082
  @max 500

  @doc "The most sub-commands Beckhoff recommends in one sum command: 500."
  @spec max() :: 500
  def max, do: @max

  @doc "A request of sum reads, each `{index_group, index_offset, length}`."
  @spec read([{ADS.index_group(), ADS.index_offset(), non_neg_integer}]) :: ADS.Command.request()
  def read([_ | _] = reads) do
    headers =
      for {group, offset, length} <- reads, into: <<>>, do: header([group, offset, length])

    length = 4 * length(reads) + Enum.sum(for {_, _, length} <- reads, do: length)
    {:read_write, @read, length(reads), length, headers}
  end

  @doc """
  The results of sum reads, from the data of the response. A device gives the data of each read
  in full, but one that gives none for those that failed is understood too.
  """
  @spec decode_read([{ADS.index_group(), ADS.index_offset(), non_neg_integer}], binary) ::
          {:ok, [{:ok, binary} | {:error, ADS.error()}]} | {:error, {:invalid_response, binary}}
  def decode_read(reads, data) do
    n = length(reads)
    lengths = for {_, _, length} <- reads, do: length

    with <<results::binary-size(4 * n), rest::binary>> <- data,
         results = for(<<result::32-little <- results>>, do: result),
         {:ok, lengths} <- read_lengths(results, lengths, byte_size(rest)) do
      {:ok, split(results, lengths, rest)}
    else
      _ -> {:error, {:invalid_response, data}}
    end
  end

  defp read_lengths(results, lengths, size) do
    cond do
      Enum.sum(lengths) == size ->
        {:ok, lengths}

      Enum.sum(for {0, length} <- Enum.zip(results, lengths), do: length) == size ->
        {:ok,
         for(
           {result, length} <- Enum.zip(results, lengths),
           do: if(result == 0, do: length, else: 0)
         )}

      true ->
        :error
    end
  end

  defp split(results, lengths, data) do
    {results, _rest} =
      Enum.zip(results, lengths)
      |> Enum.map_reduce(data, fn {result, length}, data ->
        <<part::binary-size(length), rest::binary>> = data
        {if(result == 0, do: {:ok, part}, else: error(result)), rest}
      end)

    results
  end

  @doc "A request of sum writes, each `{index_group, index_offset, data}`."
  @spec write([{ADS.index_group(), ADS.index_offset(), binary}]) :: ADS.Command.request()
  def write([_ | _] = writes) do
    headers =
      for {group, offset, data} <- writes,
          into: <<>>,
          do: header([group, offset, byte_size(data)])

    data = for {_, _, data} <- writes, into: headers, do: data
    {:read_write, @write, length(writes), 4 * length(writes), data}
  end

  @doc "The results of sum writes, from the data of the response."
  @spec decode_write([term], binary) ::
          {:ok, [:ok | {:error, ADS.error()}]} | {:error, {:invalid_response, binary}}
  def decode_write(writes, data) do
    if byte_size(data) == 4 * length(writes),
      do:
        {:ok,
         for(<<result::32-little <- data>>, do: if(result == 0, do: :ok, else: error(result)))},
      else: {:error, {:invalid_response, data}}
  end

  @doc """
  A request of sum read-writes, each `{index_group, index_offset, read_length, data}`, as for
  getting many handles at once.
  """
  @spec read_write([{ADS.index_group(), ADS.index_offset(), non_neg_integer, binary}]) ::
          ADS.Command.request()
  def read_write([_ | _] = items) do
    headers =
      for {group, offset, read_length, data} <- items,
          into: <<>>,
          do: header([group, offset, read_length, byte_size(data)])

    data = for {_, _, _, data} <- items, into: headers, do: data
    length = 8 * length(items) + Enum.sum(for {_, _, read_length, _} <- items, do: read_length)
    {:read_write, @read_write, length(items), length, data}
  end

  @doc "The results of sum read-writes, from the data of the response."
  @spec decode_read_write([term], binary) ::
          {:ok, [{:ok, binary} | {:error, ADS.error()}]} | {:error, {:invalid_response, binary}}
  def decode_read_write(items, data) do
    n = length(items)

    with <<heads::binary-size(8 * n), rest::binary>> <- data,
         heads = for(<<result::32-little, length::32-little <- heads>>, do: {result, length}),
         true <- Enum.sum(for {_, length} <- heads, do: length) == byte_size(rest) do
      {results, _rest} =
        Enum.map_reduce(heads, rest, fn {result, length}, data ->
          <<part::binary-size(length), rest::binary>> = data
          {if(result == 0, do: {:ok, part}, else: error(result)), rest}
        end)

      {:ok, results}
    else
      _ -> {:error, {:invalid_response, data}}
    end
  end

  defp header(numbers) do
    for n <- numbers, into: <<>> do
      if not (is_integer(n) and n in 0..0xFFFFFFFF),
        do: raise(ArgumentError, "a sum command of numbers of 32 bits, got: #{inspect(n)}")

      <<n::32-little>>
    end
  end

  defp error(result), do: {:error, ADS.ReturnCode.name(result)}
end
