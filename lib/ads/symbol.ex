defmodule ADS.Symbol do
  @moduledoc """
  A PLC's description of one of its variables: its name, the name of its type, where it is, and
  how big.

  A PLC has a table of its symbols when the project is built with symbols, as TwinCAT does by
  default. `ADS.Client.symbol/3` asks for one by name (index group `0xF009`), and
  `ADS.Client.symbols/2` uploads all of them (`0xF00B`, its size from `0xF00F`). Each is an entry
  of variable length:

  | Bytes | Field |
  |---|---|
  | 4 | the entry's length, padding included |
  | 4, 4 | index group and offset |
  | 4 | size in bytes |
  | 4 | ADS data type id (see `ADS.Type.id_name/1`) |
  | 4 | flags |
  | 2, 2, 2 | lengths of the name, the type and the comment |
  | ... | the name, the type and the comment, each with a zero after it |
  | 16 | the type's GUID, if flagged (`0x0008`) |
  | ... | attributes, if flagged (`0x1000`): a count of 2 bytes, then each with a byte for the length of its name and one for its value, and both with a zero after |

  Beckhoff's manuals don't describe this layout, only how to ask for it; it's written here from
  general knowledge of the format, not from another implementation's code, and is yet to be
  checked against a PLC.

  Beckhoff recommends reaching a variable by a handle from its name, as `ADS.Client` does, rather
  than by its index group and offset, which change when the program does.
  """

  defstruct name: "",
            type: "",
            index_group: 0,
            index_offset: 0,
            size: 0,
            data_type: :void,
            flags: 0,
            comment: "",
            attributes: %{},
            guid: nil

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          index_group: ADS.index_group(),
          index_offset: ADS.index_offset(),
          size: non_neg_integer,
          data_type: atom | non_neg_integer,
          flags: non_neg_integer,
          comment: String.t(),
          attributes: %{String.t() => String.t()},
          guid: String.t() | nil
        }

  @type_guid 0x0008
  @attributes 0x1000

  @flags [
    persistent: 0x0001,
    bit_value: 0x0002,
    reference_to: 0x0004,
    type_guid: 0x0008,
    tc_com_interface_pointer: 0x0010,
    read_only: 0x0020,
    interface_method_access: 0x0040,
    method_dereference: 0x0080,
    attributes: 0x1000,
    static: 0x2000,
    init_on_reset: 0x4000,
    extended_flags: 0x8000
  ]

  @doc "The symbol entry at the start of the bytes, as in the answer to a request by name."
  @spec decode(binary) :: {:ok, t} | :error
  def decode(bytes) do
    case entry(bytes) do
      {:ok, symbol, _rest} -> {:ok, symbol}
      :error -> :error
    end
  end

  @doc "Every symbol entry in the bytes, as uploaded."
  @spec decode_all(binary) :: {:ok, [t]} | :error
  def decode_all(bytes), do: entries(bytes, [])

  defp entries(<<>>, symbols), do: {:ok, Enum.reverse(symbols)}

  defp entries(bytes, symbols) do
    case entry(bytes) do
      {:ok, symbol, rest} -> entries(rest, [symbol | symbols])
      :error -> :error
    end
  end

  defp entry(<<length::32-little, _::binary>> = bytes)
       when length >= 30 and byte_size(bytes) >= length do
    <<entry::binary-size(length), rest::binary>> = bytes

    <<_length::32, group::32-little, offset::32-little, size::32-little, data_type::32-little,
      flags::32-little, name_length::16-little, type_length::16-little, comment_length::16-little,
      strings::binary>> = entry

    with {:ok, name, strings} <- string(strings, name_length),
         {:ok, type, strings} <- string(strings, type_length),
         {:ok, comment, extra} <- string(strings, comment_length) do
      {guid, extra} = if flagged?(flags, @type_guid), do: guid(extra), else: {nil, extra}

      symbol = %__MODULE__{
        name: name,
        type: type,
        index_group: group,
        index_offset: offset,
        size: size,
        data_type: ADS.Type.id_name(data_type),
        flags: flags,
        comment: comment,
        attributes: if(flagged?(flags, @attributes), do: attributes(extra), else: %{}),
        guid: guid
      }

      {:ok, symbol, rest}
    else
      _ -> :error
    end
  end

  defp entry(_bytes), do: :error

  @doc """
  The flags of a symbol by name, those that are known: `:persistent`, `:read_only` and so on.
  """
  @spec flags(t) :: [atom]
  def flags(%__MODULE__{flags: flags}),
    do: for({name, bit} <- @flags, flagged?(flags, bit), do: name)

  @doc false
  def flagged?(flags, bit), do: Bitwise.band(flags, bit) != 0

  @doc false
  # A string of a known length and a zero after it; in UTF-8 if it is valid UTF-8, as plain ASCII
  # is, or else Latin-1.
  def string(bytes, length) do
    case bytes do
      <<string::binary-size(length), 0, rest::binary>> -> {:ok, text(string), rest}
      _ -> :error
    end
  end

  @doc false
  def text(bytes),
    do: if(String.valid?(bytes), do: bytes, else: :unicode.characters_to_binary(bytes, :latin1))

  @doc false
  # A GUID as Windows writes it: the first three parts are little-endian numbers.
  def guid(<<a::32-little, b::16-little, c::16-little, d::binary-2, e::binary-6, rest::binary>>) do
    hex = &(&1 |> :binary.encode_unsigned() |> Base.encode16() |> String.pad_leading(&2, "0"))
    {"#{hex.(a, 8)}-#{hex.(b, 4)}-#{hex.(c, 4)}-#{Base.encode16(d)}-#{Base.encode16(e)}", rest}
  end

  def guid(rest), do: {nil, rest}

  @doc false
  # Attributes, name and value, such as {"TcEncoding", "UTF-8"}; what doesn't parse is left out.
  def attributes(<<count::16-little, rest::binary>>), do: attributes(rest, count, %{})
  def attributes(_bytes), do: %{}

  defp attributes(_rest, 0, attributes), do: attributes

  defp attributes(<<name_length, value_length, rest::binary>>, n, attributes) do
    case rest do
      <<name::binary-size(name_length), 0, value::binary-size(value_length), 0, rest::binary>> ->
        attributes(rest, n - 1, Map.put(attributes, text(name), text(value)))

      _ ->
        attributes
    end
  end

  defp attributes(_rest, _n, attributes), do: attributes
end
