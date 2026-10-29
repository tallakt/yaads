defmodule ADS.DataType do
  @moduledoc """
  A PLC's description of one of its data types: a structure and its members, an array, an
  enumeration and its values, or another name for a type.

  `ADS.Client.data_type/3` asks for one by name (index group `0xF011`), and
  `ADS.Client.data_types/2` uploads all of them (`0xF00E`, their size from `0xF00F`). Each is an
  entry of variable length, whose members are entries of their own inside it:

  | Bytes | Field |
  |---|---|
  | 4 | the entry's length, padding included |
  | 4 | version, 1 |
  | 4, 4 | hash values |
  | 4 | size in bytes |
  | 4 | offset, of a member in its structure |
  | 4 | ADS data type id (see `ADS.Type.id_name/1`) |
  | 4 | flags |
  | 2, 2, 2 | lengths of the name, the type and the comment |
  | 2 | dimensions of an array |
  | 2 | members of a structure |
  | ... | the name, the type and the comment, each with a zero after it |
  | 8 each | for each dimension, its first index and its number of elements |
  | ... | each member, an entry of its own |
  | 16 | the type's GUID, if flagged (`0x0080`) |
  | size | a copy mask, if flagged (`0x0200`) |
  | ... | methods, if flagged (`0x0800`): a count of 2 bytes, then entries of their own length |
  | ... | attributes, if flagged (`0x1000`), as a symbol's (see `ADS.Symbol`) |
  | ... | enumeration values, if flagged (`0x2000`): a count of 2 bytes, then each with a byte for the length of its name, the name and a zero, and the value in as many bytes as the type |

  Beckhoff's manuals don't describe this layout either; it's written here from general knowledge
  of the format, not from another implementation's code, and is yet to be checked against a PLC.
  What follows the members is read as far as it makes sense, and left out after that. In a
  structure, the offset and size of a BIT member (flagged `0x0020`) count bits.

  `to_type/2` makes an `ADS.Type` of a description, for reading and writing its values.
  """

  defstruct name: "",
            type: "",
            size: 0,
            offset: 0,
            data_type: :void,
            flags: 0,
            comment: "",
            version: 1,
            hash: 0,
            type_hash: 0,
            array: [],
            members: [],
            enum: [],
            attributes: %{},
            guid: nil

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          size: non_neg_integer,
          offset: non_neg_integer,
          data_type: atom | non_neg_integer,
          flags: non_neg_integer,
          comment: String.t(),
          version: non_neg_integer,
          hash: non_neg_integer,
          type_hash: non_neg_integer,
          array: [{integer, non_neg_integer}],
          members: [t],
          enum: [{String.t(), integer}],
          attributes: %{String.t() => String.t()},
          guid: String.t() | nil
        }

  @bit_values 0x0020
  @type_guid 0x0080
  @copy_mask 0x0200
  @method_infos 0x0800
  @attributes 0x1000
  @enum_infos 0x2000

  # Members of members, so deep and no deeper: a description from a device may be anything.
  @max_depth 32

  import ADS.Symbol, only: [flagged?: 2, string: 2]

  @doc "The data type entry at the start of the bytes, as in the answer to a request by name."
  @spec decode(binary) :: {:ok, t} | :error
  def decode(bytes) do
    case entry(bytes, 0) do
      {:ok, data_type, _rest} -> {:ok, data_type}
      :error -> :error
    end
  end

  @doc "Every data type entry in the bytes, as uploaded."
  @spec decode_all(binary) :: {:ok, [t]} | :error
  def decode_all(bytes), do: entries(bytes, [])

  defp entries(<<>>, types), do: {:ok, Enum.reverse(types)}

  defp entries(bytes, types) do
    case entry(bytes, 0) do
      {:ok, type, rest} -> entries(rest, [type | types])
      :error -> :error
    end
  end

  defp entry(<<length::32-little, _::binary>> = bytes, depth)
       when length >= 42 and byte_size(bytes) >= length and depth < @max_depth do
    <<entry::binary-size(length), rest::binary>> = bytes

    <<_length::32, version::32-little, hash::32-little, type_hash::32-little, size::32-little,
      offset::32-little, data_type::32-little, flags::32-little, name_length::16-little,
      type_length::16-little, comment_length::16-little, dimensions::16-little,
      members::16-little, strings::binary>> = entry

    with {:ok, name, strings} <- string(strings, name_length),
         {:ok, type, strings} <- string(strings, type_length),
         {:ok, comment, extra} <- string(strings, comment_length),
         {:ok, array, extra} <- array(extra, dimensions, []),
         {:ok, members, extra} <- members(extra, members, depth + 1, []) do
      data_type = %__MODULE__{
        name: name,
        type: type,
        size: size,
        offset: offset,
        data_type: ADS.Type.id_name(data_type),
        flags: flags,
        comment: comment,
        version: version,
        hash: hash,
        type_hash: type_hash,
        array: array,
        members: members
      }

      {:ok, extra(data_type, extra), rest}
    else
      _ -> :error
    end
  end

  defp entry(_bytes, _depth), do: :error

  defp array(rest, 0, dims), do: {:ok, Enum.reverse(dims), rest}

  defp array(<<first::signed-32-little, elements::32-little, rest::binary>>, n, dims),
    do: array(rest, n - 1, [{first, elements} | dims])

  defp array(_rest, _n, _dims), do: :error

  defp members(rest, 0, _depth, members), do: {:ok, Enum.reverse(members), rest}

  defp members(rest, n, depth, members) do
    case entry(rest, depth) do
      {:ok, member, rest} -> members(rest, n - 1, depth, [member | members])
      :error -> :error
    end
  end

  # What may follow the members, each part if flagged, in order; as far as it parses.
  defp extra(%__MODULE__{flags: flags} = t, bytes) do
    with {:ok, t, bytes} <- part(t, bytes, flagged?(flags, @type_guid), &guid/2),
         {:ok, t, bytes} <- part(t, bytes, flagged?(flags, @copy_mask), &copy_mask/2),
         {:ok, t, bytes} <- part(t, bytes, flagged?(flags, @method_infos), &methods/2),
         {:ok, t, bytes} <- part(t, bytes, flagged?(flags, @attributes), &attributes/2),
         {:ok, t, _bytes} <- part(t, bytes, flagged?(flags, @enum_infos), &enum/2) do
      t
    else
      {:stop, t} -> t
    end
  end

  defp part(t, bytes, false, _parse), do: {:ok, t, bytes}

  defp part(t, bytes, true, parse) do
    case parse.(t, bytes) do
      {:ok, t, bytes} -> {:ok, t, bytes}
      :error -> {:stop, t}
    end
  end

  defp guid(t, bytes) do
    case ADS.Symbol.guid(bytes) do
      {nil, _bytes} -> :error
      {guid, rest} -> {:ok, %{t | guid: guid}, rest}
    end
  end

  defp copy_mask(%{size: size} = t, bytes) do
    case bytes do
      <<_mask::binary-size(size), rest::binary>> -> {:ok, t, rest}
      _ -> :error
    end
  end

  defp methods(t, <<count::16-little, rest::binary>>), do: skip_entries(t, rest, count)
  defp methods(_t, _bytes), do: :error

  defp skip_entries(t, rest, 0), do: {:ok, t, rest}

  defp skip_entries(t, <<length::32-little, _::binary>> = bytes, n)
       when length >= 4 and byte_size(bytes) >= length do
    <<_entry::binary-size(length), rest::binary>> = bytes
    skip_entries(t, rest, n - 1)
  end

  defp skip_entries(_t, _bytes, _n), do: :error

  defp attributes(t, <<count::16-little, _::binary>> = bytes) do
    attributes = ADS.Symbol.attributes(bytes)

    if map_size(attributes) == count,
      do: {:ok, %{t | attributes: attributes}, skip_attributes(bytes)},
      else: :error
  end

  defp attributes(_t, _bytes), do: :error

  defp skip_attributes(<<count::16-little, rest::binary>>), do: skip_attributes(rest, count)
  defp skip_attributes(rest, 0), do: rest

  defp skip_attributes(<<name_length, value_length, rest::binary>>, n) do
    <<_::binary-size(name_length), 0, _::binary-size(value_length), 0, rest::binary>> = rest
    skip_attributes(rest, n - 1)
  end

  defp enum(t, <<count::16-little, rest::binary>>), do: enum_values(t, rest, count, [])
  defp enum(_t, _bytes), do: :error

  defp enum_values(t, rest, 0, values), do: {:ok, %{t | enum: Enum.reverse(values)}, rest}

  defp enum_values(%{size: size} = t, <<name_length, rest::binary>>, n, values) do
    case rest do
      <<name::binary-size(name_length), 0, value::binary-size(size), rest::binary>>
      when size > 0 ->
        value = enum_value(value, t.data_type)
        enum_values(t, rest, n - 1, [{ADS.Symbol.text(name), value} | values])

      _ ->
        :error
    end
  end

  defp enum_values(_t, _bytes, _n, _values), do: :error

  defp enum_value(bytes, data_type) when data_type in [:int8, :int16, :int32, :int64] do
    bits = bit_size(bytes)
    <<n::signed-little-size(bits)>> = bytes
    n
  end

  defp enum_value(bytes, _data_type), do: :binary.decode_unsigned(bytes, :little)

  @doc """
  The `ADS.Type` of a data type. `resolve` gives the type of a name the description refers to,
  with the size it must have, as `{:ok, type}`, or anything else when it can't; `ADS.Client` asks
  the PLC. What can't be made out, such as a member whose type is unknown, is `{:raw, size}`: its
  bytes, so that the rest still decode.

      iex> pump = %ADS.DataType{name: "ST_Pump", size: 16, data_type: :big_type, members: [
      ...>   %ADS.DataType{name: "nSpeed", type: "INT", size: 2, offset: 0, data_type: :int16},
      ...>   %ADS.DataType{name: "fTemp", type: "LREAL", size: 8, offset: 8, data_type: :real64}]}
      iex> ADS.DataType.to_type(pump, fn _name, _size -> :error end)
      {:struct, 16, [{"nSpeed", 0, :int}, {"fTemp", 8, :lreal}]}
  """
  @spec to_type(t, (String.t(), non_neg_integer -> {:ok, ADS.Type.t()} | term)) :: ADS.Type.t()
  def to_type(%__MODULE__{} = t, resolve), do: type(t, resolve, 0)

  defp type(%{size: size}, _resolve, depth) when depth >= @max_depth, do: {:raw, size}

  defp type(t, resolve, depth) do
    type =
      cond do
        t.enum != [] -> enumeration(t)
        t.members != [] -> structure(t, resolve, depth)
        t.array != [] -> array_type(t, resolve, depth)
        true -> named(t.type, t.size, t.data_type, resolve)
      end

    if fits?(type, t.size), do: type, else: {:raw, t.size}
  end

  defp fits?(type, size) do
    _ = ADS.Type.check!(type)
    ADS.Type.size(type) == size
  rescue
    ArgumentError -> false
  end

  defp enumeration(t) do
    case ADS.Type.from_id(t.data_type, t.size) || parsed(t.type, t.size) do
      base when base in [:sint, :usint, :int, :uint, :dint, :udint, :lint, :ulint] ->
        {:enum, base, t.enum}

      base when base in [:byte, :word, :dword, :lword] ->
        {:enum, base, t.enum}

      _ ->
        {:raw, t.size}
    end
  end

  defp parsed(name, size) do
    case ADS.Type.parse(name, size) do
      {:ok, type} -> type
      :error -> nil
    end
  end

  defp structure(t, resolve, depth) do
    members =
      for member <- t.members do
        if flagged?(member.flags, @bit_values) or String.upcase(member.type) == "BIT",
          do: {member.name, member.offset, :bit},
          else: {member.name, member.offset, member_type(member, resolve, depth)}
      end

    union? =
      length(members) > 1 and Enum.all?(members, &match?({_, 0, type} when type != :bit, &1))

    {if(union?, do: :union, else: :struct), t.size, members}
  end

  defp member_type(member, resolve, depth) do
    if member.members != [] or member.array != [] or member.enum != [],
      do: type(member, resolve, depth + 1),
      else: named(member.type, member.size, member.data_type, resolve)
  end

  # An array's type names its elements, or the array itself.
  defp array_type(t, resolve, _depth) do
    dims = for {first, elements} <- t.array, do: {first, first + elements - 1}
    n = Enum.reduce(t.array, 1, fn {_first, elements}, n -> n * elements end)

    case resolve(resolve, t.type, t.size) do
      {:array, _element, _dims} = type ->
        if fits?(type, t.size), do: type, else: array_of(t, dims, n, resolve)

      _ ->
        array_of(t, dims, n, resolve)
    end
  end

  defp array_of(t, dims, n, resolve) do
    if n > 0 and rem(t.size, n) == 0,
      do: {:array, named(t.type, div(t.size, n), t.data_type, resolve), dims},
      else: {:raw, t.size}
  end

  # The type of a name, of the size it must be: built in, from resolve, or by its data type id.
  defp named(name, size, data_type, resolve) do
    type = resolve(resolve, name, size)

    cond do
      type != nil and fits?(type, size) -> type
      type = ADS.Type.from_id(data_type, size) -> type
      true -> {:raw, size}
    end
  end

  defp resolve(resolve, name, size) do
    case ADS.Type.parse(name, size) do
      {:ok, type} ->
        type

      :error ->
        case resolve.(name, size) do
          {:ok, type} -> type
          _ -> nil
        end
    end
  end
end
