defmodule ADS.Type do
  @moduledoc """
  The data types of a TwinCAT PLC, and their values as Elixir terms.

  | PLC | Type | Value |
  |---|---|---|
  | BOOL | `:bool` | `true` or `false` |
  | BYTE, WORD, DWORD, LWORD | `:byte`, `:word`, `:dword`, `:lword` | an integer |
  | SINT, USINT, INT, UINT, DINT, UDINT, LINT, ULINT | `:sint`, `:usint`, `:int`, ... `:ulint` | an integer |
  | REAL, LREAL | `:real`, `:lreal` | a float, or `:nan`, `:infinity`, `:neg_infinity` |
  | STRING(n) | `{:string, n}`, or `{:string, n, :utf8}` | a string |
  | WSTRING(n) | `{:wstring, n}` | a string |
  | TIME, LTIME | `:time`, `:ltime` | an integer of ms, or of ns |
  | TIME_OF_DAY, LTIME_OF_DAY | `:time_of_day`, `:ltime_of_day` | a `Time` |
  | DATE, LDATE | `:date`, `:ldate` | a `Date` |
  | DATE_AND_TIME, LDATE_AND_TIME | `:date_and_time`, `:ldate_and_time` | a `NaiveDateTime` |
  | ARRAY [a..b, c..d] OF T | `{:array, t, [{a, b}, {c, d}]}` | a list, nested for each dimension |
  | STRUCT, FUNCTION_BLOCK | `{:struct, size, [{name, offset, t}]}` | a map of the members' names to their values |
  | UNION | `{:union, size, [{name, offset, t}]}` | a map of every member; one at a time when written |
  | an enumeration | `{:enum, t, [{name, value}]}` | the name of the value, or its number if it has none |
  | BIT, in a structure | `:bit` | `true` or `false` |
  | anything else | `{:raw, size}` | its bytes |

      iex> ADS.Type.encode(:int, -2)
      <<254, 255>>
      iex> ADS.Type.decode({:string, 10}, "Pump 1" <> <<0::40>>)
      {:ok, "Pump 1"}
      iex> ADS.Type.parse("ARRAY [1..3] OF LREAL")
      {:ok, {:array, :lreal, [{1, 3}]}}

  Numbers are little-endian, as everything in ADS. A STRING(n) takes n + 1 bytes, the last for the
  zero that ends it, and holds Latin-1 unless declared with the attribute `'TcEncoding' := 'UTF-8'`;
  a WSTRING(n) takes 2(n + 1), in UCS-2, which has no characters past U+FFFF. TIME counts ms and
  LTIME ns; TIME_OF_DAY ms since midnight and LTIME_OF_DAY ns; DATE and DATE_AND_TIME seconds since
  1970, and LDATE and LDATE_AND_TIME ns, as signed 64-bit numbers. A PLC's dates and times have no
  time zone, so they are naive here; LDATE_AND_TIME and LTIME_OF_DAY keep microseconds, dropping
  the last three digits of their ns. A time of day past midnight, which no PLC makes but bytes can
  hold, is its number.

  A structure's members, a union's and an array's elements are where the PLC puts them: given by
  the PLC's description of the type, or by `layout/2`, which follows TwinCAT 3's rules for
  alignment. In a structure, the offset of a `:bit` member counts bits, from the lowest bit of the
  structure's first byte.

  `encode/2` raises `ArgumentError` for a value that doesn't fit its type, such as 70000 as an INT
  or a struct with a member missing. `decode/2` never raises for any bytes of the right size.
  """

  @type t ::
          :bool
          | :bit
          | :byte
          | :word
          | :dword
          | :lword
          | :sint
          | :usint
          | :int
          | :uint
          | :dint
          | :udint
          | :lint
          | :ulint
          | :real
          | :lreal
          | :time
          | :ltime
          | :date
          | :date_and_time
          | :time_of_day
          | :ldate
          | :ldate_and_time
          | :ltime_of_day
          | {:string, non_neg_integer}
          | {:string, non_neg_integer, :utf8}
          | {:wstring, non_neg_integer}
          | {:array, t, [{integer, integer}]}
          | {:struct, non_neg_integer, [member]}
          | {:union, non_neg_integer, [member]}
          | {:enum, t, [{String.t(), integer}]}
          | {:raw, non_neg_integer}

  @typedoc "A member of a structure: its name, offset in bytes (in bits for `:bit`), and type."
  @type member :: {String.t(), non_neg_integer, t}

  @sizes %{
    bool: 1,
    bit: 1,
    byte: 1,
    word: 2,
    dword: 4,
    lword: 8,
    sint: 1,
    usint: 1,
    int: 2,
    uint: 2,
    dint: 4,
    udint: 4,
    lint: 8,
    ulint: 8,
    real: 4,
    lreal: 8,
    time: 4,
    ltime: 8,
    date: 4,
    date_and_time: 4,
    time_of_day: 4,
    ldate: 8,
    ldate_and_time: 8,
    ltime_of_day: 8
  }

  @integers %{
    byte: :unsigned,
    word: :unsigned,
    dword: :unsigned,
    lword: :unsigned,
    usint: :unsigned,
    uint: :unsigned,
    udint: :unsigned,
    ulint: :unsigned,
    sint: :signed,
    int: :signed,
    dint: :signed,
    lint: :signed
  }

  @names %{
    "BOOL" => :bool,
    "BIT" => :bit,
    "BYTE" => :byte,
    "WORD" => :word,
    "DWORD" => :dword,
    "LWORD" => :lword,
    "SINT" => :sint,
    "USINT" => :usint,
    "INT" => :int,
    "UINT" => :uint,
    "DINT" => :dint,
    "UDINT" => :udint,
    "LINT" => :lint,
    "ULINT" => :ulint,
    "REAL" => :real,
    "LREAL" => :lreal,
    "TIME" => :time,
    "LTIME" => :ltime,
    "DATE" => :date,
    "DATE_AND_TIME" => :date_and_time,
    "DT" => :date_and_time,
    "TIME_OF_DAY" => :time_of_day,
    "TOD" => :time_of_day,
    "LDATE" => :ldate,
    "LDATE_AND_TIME" => :ldate_and_time,
    "LDT" => :ldate_and_time,
    "LTIME_OF_DAY" => :ltime_of_day,
    "LTOD" => :ltime_of_day
  }

  # Of the target's size: 4 bytes on a 32-bit system, 8 on a 64-bit one.
  @platform %{
    "XINT" => {:dint, :lint},
    "UXINT" => {:udint, :ulint},
    "XWORD" => {:dword, :lword},
    "PVOID" => {:udint, :ulint}
  }

  # ADS data type ids, as a symbol or a data type describes itself (ADSDATATYPEID).
  @ids %{
    0 => :void,
    2 => :int16,
    3 => :int32,
    4 => :real32,
    5 => :real64,
    12 => :variant,
    16 => :int8,
    17 => :uint8,
    18 => :uint16,
    19 => :uint32,
    20 => :int64,
    21 => :uint64,
    30 => :string,
    31 => :wstring,
    32 => :real80,
    33 => :bit,
    65 => :big_type
  }

  @by_id %{
    int8: :sint,
    uint8: :usint,
    int16: :int,
    uint16: :uint,
    int32: :dint,
    uint32: :udint,
    int64: :lint,
    uint64: :ulint,
    real32: :real,
    real64: :lreal,
    bit: :bool
  }

  @unix ~N[1970-01-01 00:00:00]
  @day_ms 86_400_000
  @day_ns 86_400_000_000_000

  @doc "The size of a type's values in bytes."
  @spec size(t) :: non_neg_integer
  def size(type) when is_map_key(@sizes, type), do: Map.fetch!(@sizes, type)
  def size({:string, n}), do: n + 1
  def size({:string, n, :utf8}), do: n + 1
  def size({:wstring, n}), do: 2 * (n + 1)
  def size({:array, type, dims}), do: count(dims) * size(type)
  def size({kind, size, _members}) when kind in [:struct, :union], do: size
  def size({:enum, type, _values}), do: size(type)
  def size({:raw, size}), do: size

  defp count(dims),
    do: Enum.reduce(dims, 1, fn {first, last}, n -> n * max(last - first + 1, 0) end)

  @doc """
  The type of a PLC type name, for the types TwinCAT has built in, strings, arrays of them, and
  subranges such as `INT (0..100)`; `:error` for any other, such as a structure, whose description
  the PLC has. POINTER TO, REFERENCE TO, XINT and the like are as big as the target's addresses,
  which `size`, the size of a value, tells.

      iex> ADS.Type.parse("STRING(80)")
      {:ok, {:string, 80}}
      iex> ADS.Type.parse("ARRAY [0..1, -1..1] OF INT")
      {:ok, {:array, :int, [{0, 1}, {-1, 1}]}}
      iex> ADS.Type.parse("POINTER TO REAL", 8)
      {:ok, :ulint}
      iex> ADS.Type.parse("ST_Pump")
      :error
  """
  @spec parse(String.t(), non_neg_integer | nil) :: {:ok, t} | :error
  def parse(name, size \\ nil) when is_binary(name) do
    name = String.trim(name)
    upper = String.upcase(name)

    cond do
      Map.has_key?(@names, upper) ->
        {:ok, Map.fetch!(@names, upper)}

      Map.has_key?(@platform, upper) ->
        platform(Map.fetch!(@platform, upper), size)

      String.starts_with?(upper, ["POINTER TO ", "REFERENCE TO "]) ->
        platform({:udint, :ulint}, size)

      String.starts_with?(upper, "ARRAY") ->
        array(upper, size)

      String.starts_with?(upper, ["STRING", "WSTRING"]) ->
        string(String.replace(upper, " ", ""))

      String.contains?(upper, "(") ->
        subrange(name, size)

      true ->
        :error
    end
  end

  defp platform({small, _large}, 4), do: {:ok, small}
  defp platform({_small, large}, 8), do: {:ok, large}
  defp platform(_types, _size), do: :error

  defp string("STRING"), do: {:ok, {:string, 80}}
  defp string("WSTRING"), do: {:ok, {:wstring, 80}}
  defp string("STRING" <> length), do: string_length(length, :string)
  defp string("WSTRING" <> length), do: string_length(length, :wstring)

  defp string_length(<<open, rest::binary>>, kind) when open in [?(, ?[] do
    case Integer.parse(rest) do
      {n, close} when n >= 0 and close in [")", "]"] -> {:ok, {kind, n}}
      _ -> :error
    end
  end

  defp string_length(_rest, _kind), do: :error

  # ARRAY [0..9, 1..2] OF T, or ARRAY [0..9][1..2] OF T as Beckhoff's .NET libraries name it, where
  # T is any type parse/2 knows, arrays of them included. All of it in upper case, as offsets in it
  # aren't those in the name where upcasing makes a character longer.
  defp array(upper, size) do
    with {open, 1} <- :binary.match(upper, "["),
         {close, 1} <- :binary.match(upper, "]"),
         true <- open < close,
         {of, 4} <- :binary.match(upper, " OF ", scope: {close, byte_size(upper) - close}),
         {:ok, dims} <- bounds(binary_part(upper, open, of - open)),
         {:ok, type} <-
           parse(binary_part(upper, of + 4, byte_size(upper) - of - 4), element(size, dims)) do
      {:ok, {:array, type, dims}}
    else
      _ -> :error
    end
  end

  # Each [...] in turn, and nothing else.
  defp bounds(text) do
    {groups, [rest]} = text |> String.split("]") |> Enum.split(-1)
    if String.trim(rest) == "", do: groups(groups, []), else: :error
  end

  defp groups([], dims), do: {:ok, dims}

  defp groups([group | groups], dims) do
    with "[" <> group <- String.trim(group),
         {:ok, more} <- dims(group) do
      groups(groups, dims ++ more)
    else
      _ -> :error
    end
  end

  defp dims(text) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn dim, {:ok, dims} ->
      with [first, last] <- dim |> String.trim() |> String.split(".."),
           {first, ""} <- Integer.parse(String.trim(first)),
           {last, ""} <- Integer.parse(String.trim(last)),
           true <- last >= first do
        {:cont, {:ok, dims ++ [{first, last}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp element(nil, _dims), do: nil

  defp element(size, dims) do
    n = count(dims)
    if n > 0 and rem(size, n) == 0, do: div(size, n)
  end

  # INT (0..100): the base type, with a range the PLC checks and ADS doesn't.
  defp subrange(name, size) do
    [base | _] = String.split(name, "(", parts: 2)
    base = String.trim(base)

    case parse(base, size) do
      {:ok, type} when is_map_key(@integers, type) -> {:ok, type}
      _ -> :error
    end
  end

  @doc """
  The name of an ADS data type id, as a symbol or a data type describes itself, or the id if it
  has none: `:int16` for 2, `:big_type` for 65, the id of structures and arrays.
  """
  @spec id_name(non_neg_integer) :: atom | non_neg_integer
  def id_name(id), do: Map.get(@ids, id, id)

  @doc """
  The type of a value of `size` bytes by its ADS data type id alone, or nil: for when a type's name
  says nothing parse/2 knows.

      iex> ADS.Type.from_id(:uint16, 2)
      :uint
      iex> ADS.Type.from_id(:string, 81)
      {:string, 80}
      iex> ADS.Type.from_id(:big_type, 12)
      nil
  """
  @spec from_id(atom | non_neg_integer, non_neg_integer) :: t | nil
  def from_id(id, size) when is_integer(id) do
    case id_name(id) do
      name when is_atom(name) -> from_id(name, size)
      _unknown -> nil
    end
  end

  def from_id(:string, size) when size >= 1, do: {:string, size - 1}

  def from_id(:wstring, size) when size >= 2 and rem(size, 2) == 0,
    do: {:wstring, div(size, 2) - 1}

  def from_id(id, size) do
    case @by_id do
      %{^id => type} -> if size(type) == size, do: type
      _ -> nil
    end
  end

  @doc """
  A structure of members, each `{name, type}`, placed by TwinCAT 3's rules for alignment: each
  member at an offset that's a multiple of the size of its type, or of `:pack_mode` if that's
  smaller; strings at any byte; consecutive BIT members together in bytes; and the structure as a
  whole a multiple of its most aligned member in size, so that an array of them stays aligned.

    * `:pack_mode` - 8, TwinCAT 3's default, or 4, 2, 1 or 0 (none), as with the attribute
      `'pack_mode'` of the structure; TwinCAT 2 had 1 on x86

  For a structure on the PLC, the description the PLC has of its type is surer.

      iex> ADS.Type.layout([{"fVar", :lreal}, {"nVar1", :dint}, {"nVar2", :sint}])
      {:struct, 16, [{"fVar", 0, :lreal}, {"nVar1", 8, :dint}, {"nVar2", 12, :sint}]}
      iex> ADS.Type.layout([{"nVar2", :sint}, {"fVar", :lreal}], pack_mode: 1)
      {:struct, 9, [{"nVar2", 0, :sint}, {"fVar", 1, :lreal}]}
  """
  @spec layout([{String.t(), t}], keyword) :: t
  def layout(members, opts \\ []) when is_list(members) do
    pack = Keyword.get(opts, :pack_mode, 8)

    if pack not in [0, 1, 2, 4, 8],
      do: raise(ArgumentError, "pack_mode: is 0, 1, 2, 4 or 8, got: #{inspect(pack)}")

    pack = max(pack, 1)

    {placed, offset, bit} =
      Enum.reduce(members, {[], 0, nil}, fn
        {name, :bit}, {placed, offset, bit} ->
          bit = bit || offset * 8
          {[{to_string(name), bit, :bit} | placed], offset, bit + 1}

        {name, type}, {placed, offset, bit} ->
          type = check!(type)
          offset = if bit, do: ceil_div(bit, 8), else: offset
          offset = round_up(offset, alignment(type, pack))
          {[{to_string(name), offset, type} | placed], offset + size(type), nil}

        member, _acc ->
          raise ArgumentError, "a member is {name, type}, got: #{inspect(member)}"
      end)

    placed = Enum.reverse(placed)
    end_offset = if bit, do: ceil_div(bit, 8), else: offset
    {:struct, round_up(end_offset, struct_alignment(placed, pack)), placed}
  end

  defp alignment(:bit, _pack), do: 1
  defp alignment(type, pack) when is_atom(type), do: min(size(type), pack)
  defp alignment({kind, _n}, _pack) when kind in [:string, :wstring], do: 1
  defp alignment({:string, _n, _encoding}, _pack), do: 1
  defp alignment({:array, type, _dims}, pack), do: alignment(type, pack)

  defp alignment({kind, _size, members}, pack) when kind in [:struct, :union],
    do: struct_alignment(members, pack)

  defp alignment({:enum, type, _values}, pack), do: alignment(type, pack)
  defp alignment({:raw, _size}, _pack), do: 1

  defp struct_alignment(members, pack),
    do: Enum.reduce(members, 1, fn {_name, _offset, type}, a -> max(a, alignment(type, pack)) end)

  defp round_up(n, a), do: ceil_div(n, a) * a
  defp ceil_div(n, d), do: div(n + d - 1, d)

  @doc """
  The type itself, if it's one; raises `ArgumentError` if it isn't, as for a member that doesn't
  fit in its structure.
  """
  @spec check!(term) :: t
  def check!(type) do
    if valid?(type), do: type, else: raise(ArgumentError, "not an ADS.Type: #{inspect(type)}")
  end

  defp valid?(type) when is_atom(type), do: Map.has_key?(@sizes, type)
  defp valid?({kind, n}) when kind in [:string, :wstring], do: non_negative?(n)
  defp valid?({:string, n, :utf8}), do: non_negative?(n)
  defp valid?({:raw, n}), do: non_negative?(n)

  defp valid?({:array, type, [_ | _] = dims}),
    do:
      valid?(type) and
        Enum.all?(
          dims,
          &match?({first, last} when is_integer(first) and is_integer(last) and last >= first, &1)
        )

  defp valid?({:enum, type, values}) when is_map_key(@integers, type) and is_list(values),
    do: Enum.all?(values, &match?({name, value} when is_binary(name) and is_integer(value), &1))

  defp valid?({kind, size, members}) when kind in [:struct, :union] and is_list(members),
    do: non_negative?(size) and Enum.all?(members, &member?(&1, size))

  defp valid?(_type), do: false

  defp member?({name, bit, :bit}, size) when is_binary(name),
    do: non_negative?(bit) and bit < size * 8

  defp member?({name, offset, type}, size) when is_binary(name),
    do: non_negative?(offset) and valid?(type) and offset + size(type) <= size

  defp member?(_member, _size), do: false

  defp non_negative?(n), do: is_integer(n) and n >= 0

  @doc "A value from its bytes, or `:error` if there aren't as many as the type takes."
  @spec decode(t, binary) :: {:ok, term} | :error
  def decode(type, bytes) when is_binary(bytes) do
    if byte_size(bytes) == size(type), do: {:ok, value(type, bytes)}, else: :error
  catch
    # A member that doesn't fit its structure, in a type from a device's description.
    :invalid -> :error
  end

  defp value(:bool, <<byte>>), do: byte != 0
  defp value(:bit, <<byte>>), do: byte != 0

  defp value(type, bytes) when is_map_key(@integers, type),
    do: integer(bytes, Map.fetch!(@integers, type))

  defp value(type, bytes) when type in [:real, :lreal], do: float(bytes)
  defp value(:time, <<ms::32-little>>), do: ms
  defp value(:ltime, <<ns::64-little>>), do: ns
  defp value(:date, <<s::32-little>>), do: Date.add(~D[1970-01-01], div(s, 86_400))
  defp value(:date_and_time, <<s::32-little>>), do: NaiveDateTime.add(@unix, s)

  defp value(:time_of_day, <<ms::32-little>>) when ms < @day_ms,
    do: Time.from_seconds_after_midnight(div(ms, 1000), {rem(ms, 1000) * 1000, 3})

  defp value(:time_of_day, <<ms::32-little>>), do: ms

  defp value(:ldate, <<ns::signed-64-little>>),
    do: Date.add(~D[1970-01-01], Integer.floor_div(ns, @day_ns))

  defp value(:ldate_and_time, <<ns::signed-64-little>>),
    do:
      NaiveDateTime.add(%{@unix | microsecond: {0, 6}}, Integer.floor_div(ns, 1000), :microsecond)

  defp value(:ltime_of_day, <<ns::64-little>>) when ns < @day_ns,
    do:
      Time.from_seconds_after_midnight(
        div(ns, 1_000_000_000),
        {div(rem(ns, 1_000_000_000), 1000), 6}
      )

  defp value(:ltime_of_day, <<ns::64-little>>), do: ns
  # The last character is the zero that ends a string, whatever the bytes say: n at most.
  defp value({:string, n}, bytes),
    do: bytes |> cstring(n) |> :unicode.characters_to_binary(:latin1)

  defp value({:string, n, :utf8}, bytes), do: bytes |> cstring(n) |> utf8()
  defp value({:wstring, n}, bytes), do: bytes |> binary_part(0, 2 * n) |> wcstring(0) |> ucs2()
  defp value({:array, type, dims}, bytes), do: nest(elements(type, bytes, count(dims)), dims)

  defp value({kind, _size, members}, bytes) when kind in [:struct, :union],
    do: Map.new(members, &member(&1, bytes))

  defp value({:enum, type, values}, bytes) do
    n = value(type, bytes)

    case List.keyfind(values, n, 1) do
      {name, _n} -> name
      nil -> n
    end
  end

  defp value({:raw, _size}, bytes), do: bytes

  defp integer(bytes, :unsigned), do: :binary.decode_unsigned(bytes, :little)

  defp integer(bytes, :signed) do
    bits = bit_size(bytes)
    <<n::signed-little-size(bits)>> = bytes
    n
  end

  # Infinities and NaNs don't match a float, and are told apart by their mantissa and sign.
  defp float(bytes) do
    bits = bit_size(bytes)

    case bytes do
      <<x::float-little-size(bits)>> ->
        x

      _special ->
        n = :binary.decode_unsigned(bytes, :little)
        mantissa = Bitwise.band(n, if(bits == 32, do: 0x7FFFFF, else: 0xFFFFFFFFFFFFF))
        negative = Bitwise.bsr(n, bits - 1) == 1

        cond do
          mantissa != 0 -> :nan
          negative -> :neg_infinity
          true -> :infinity
        end
    end
  end

  defp cstring(bytes, n), do: bytes |> binary_part(0, n) |> :binary.split(<<0>>) |> hd()

  # Up to the first zero WORD.
  defp wcstring(bytes, i) do
    case bytes do
      <<_::binary-size(i), 0, 0, _::binary>> -> binary_part(bytes, 0, i)
      <<_::binary-size(i), _, _, _::binary>> -> wcstring(bytes, i + 2)
      _ -> binary_part(bytes, 0, i)
    end
  end

  # What isn't valid becomes U+FFFD, as bytes from a device may be anything.
  defp utf8(bytes) do
    case :unicode.characters_to_binary(bytes) do
      string when is_binary(string) -> string
      {_, good, <<_, rest::binary>>} -> good <> "�" <> utf8(rest)
      {_, good, _} -> good <> "�"
    end
  end

  # UCS-2, a character to each WORD: a surrogate, which UCS-2 hasn't, becomes U+FFFD, so that what
  # is read can be written back.
  defp ucs2(bytes) do
    for <<unit::16-little <- bytes>>, into: "" do
      if unit in 0xD800..0xDFFF, do: "�", else: <<unit::utf8>>
    end
  end

  defp elements(type, bytes, n) do
    case size(type) do
      0 -> List.duplicate(value(type, <<>>), n)
      size -> for <<part::binary-size(size) <- bytes>>, do: value(type, part)
    end
  end

  defp nest(values, [_dim]), do: values

  defp nest(values, [_dim | dims]) do
    n = count(dims)
    if n == 0, do: [], else: values |> Enum.chunk_every(n) |> Enum.map(&nest(&1, dims))
  end

  defp member({name, bit, :bit}, bytes) do
    case bytes do
      <<_::binary-size(div(bit, 8)), byte, _::binary>> ->
        {name, Bitwise.band(Bitwise.bsr(byte, rem(bit, 8)), 1) == 1}

      _ ->
        throw(:invalid)
    end
  end

  defp member({name, offset, type}, bytes) do
    size = size(type)

    if offset + size <= byte_size(bytes),
      do: {name, value(type, binary_part(bytes, offset, size))},
      else: throw(:invalid)
  end

  @doc "A value as bytes; raises `ArgumentError` if it doesn't fit the type."
  @spec encode(t, term) :: binary
  def encode(type, value) do
    bytes(type, value)
  rescue
    # A value of the wrong kind for its type, such as a string for an INT, matches no clause.
    _ in [FunctionClauseError, MatchError] ->
      reraise ArgumentError,
              [message: "#{inspect(value)} doesn't fit #{inspect(type)}"],
              __STACKTRACE__
  end

  defp bytes(type, value) when type in [:bool, :bit] and is_boolean(value),
    do: if(value, do: <<1>>, else: <<0>>)

  defp bytes(type, n) when is_map_key(@integers, type) and is_integer(n) do
    bits = 8 * size(type)

    case Map.fetch!(@integers, type) do
      :unsigned -> fits!(n, 0, Bitwise.bsl(1, bits) - 1, type)
      :signed -> fits!(n, -Bitwise.bsl(1, bits - 1), Bitwise.bsl(1, bits - 1) - 1, type)
    end

    <<n::little-size(bits)>>
  end

  defp bytes(:real, x), do: float_bytes(x, 32)
  defp bytes(:lreal, x), do: float_bytes(x, 64)
  defp bytes(:time, ms) when is_integer(ms), do: <<fits!(ms, 0, 0xFFFFFFFF, :time)::32-little>>

  defp bytes(:ltime, ns) when is_integer(ns),
    do: <<fits!(ns, 0, 0xFFFFFFFFFFFFFFFF, :ltime)::64-little>>

  defp bytes(:date, %Date{} = date),
    do: <<fits!(Date.diff(date, ~D[1970-01-01]) * 86_400, 0, 0xFFFFFFFF, :date)::32-little>>

  defp bytes(:date_and_time, datetime) do
    s = NaiveDateTime.diff(naive(datetime), @unix)
    <<fits!(s, 0, 0xFFFFFFFF, :date_and_time)::32-little>>
  end

  defp bytes(:time_of_day, %Time{} = time) do
    {s, us} = Time.to_seconds_after_midnight(time)
    <<s * 1000 + div(us, 1000)::32-little>>
  end

  defp bytes(:time_of_day, ms) when is_integer(ms),
    do: <<fits!(ms, 0, 0xFFFFFFFF, :time_of_day)::32-little>>

  defp bytes(:ldate, %Date{} = date),
    do: <<signed64!(Date.diff(date, ~D[1970-01-01]) * @day_ns, :ldate)::signed-64-little>>

  defp bytes(:ldate_and_time, datetime) do
    ns = NaiveDateTime.diff(naive(datetime), @unix, :microsecond) * 1000
    <<signed64!(ns, :ldate_and_time)::signed-64-little>>
  end

  defp bytes(:ltime_of_day, %Time{} = time) do
    {s, us} = Time.to_seconds_after_midnight(time)
    <<s * 1_000_000_000 + us * 1000::64-little>>
  end

  defp bytes(:ltime_of_day, ns) when is_integer(ns),
    do: <<fits!(ns, 0, 0xFFFFFFFFFFFFFFFF, :ltime_of_day)::64-little>>

  defp bytes({:string, n}, string) when is_binary(string) do
    case :unicode.characters_to_binary(string, :utf8, :latin1) do
      latin1 when is_binary(latin1) -> pad(latin1, n, 1, {:string, n})
      _ -> raise ArgumentError, "#{inspect(string)} has characters Latin-1 doesn't, for a STRING"
    end
  end

  defp bytes({:string, n, :utf8}, string) when is_binary(string) do
    if not String.valid?(string), do: raise(ArgumentError, "not UTF-8: #{inspect(string)}")
    pad(string, n, 1, {:string, n, :utf8})
  end

  defp bytes({:wstring, n}, string) when is_binary(string) do
    if not String.valid?(string) or Enum.any?(String.to_charlist(string), &(&1 > 0xFFFF)),
      do: raise(ArgumentError, "#{inspect(string)} has characters UCS-2 doesn't, for a WSTRING")

    string |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> pad(n, 2, {:wstring, n})
  end

  defp bytes({:array, type, dims}, values), do: array_bytes(type, dims, values)
  defp bytes({:struct, size, members}, map) when is_map(map), do: struct_bytes(size, members, map)

  defp bytes({:union, size, members}, map) when is_map(map) and map_size(map) == 1 do
    [{{_name, offset, type}, value}] = values(members, map, :some)
    member = bytes(type, value)
    <<0::size(offset * 8), member::binary, 0::size((size - offset - byte_size(member)) * 8)>>
  end

  defp bytes({:enum, type, values}, name) when is_binary(name) do
    case Enum.find(values, fn {n, _} -> String.downcase(n) == String.downcase(name) end) do
      {_name, n} -> bytes(type, n)
      nil -> raise ArgumentError, "#{inspect(name)} isn't a value of #{inspect(values)}"
    end
  end

  defp bytes({:enum, type, _values}, n) when is_integer(n), do: bytes(type, n)
  defp bytes({:raw, size}, bytes) when is_binary(bytes) and byte_size(bytes) == size, do: bytes

  defp fits!(n, min, max, _type) when n >= min and n <= max, do: n

  defp fits!(n, _min, _max, type),
    do: raise(ArgumentError, "#{inspect(n)} is out of range for #{inspect(type)}")

  defp signed64!(n, type),
    do: fits!(n, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF, type)

  defp naive(%NaiveDateTime{} = datetime), do: datetime
  defp naive(%DateTime{} = datetime), do: DateTime.to_naive(datetime)

  defp float_bytes(:nan, 32), do: <<0, 0, 0xC0, 0x7F>>
  defp float_bytes(:infinity, 32), do: <<0, 0, 0x80, 0x7F>>
  defp float_bytes(:neg_infinity, 32), do: <<0, 0, 0x80, 0xFF>>
  defp float_bytes(:nan, 64), do: <<0, 0, 0, 0, 0, 0, 0xF8, 0x7F>>
  defp float_bytes(:infinity, 64), do: <<0, 0, 0, 0, 0, 0, 0xF0, 0x7F>>
  defp float_bytes(:neg_infinity, 64), do: <<0, 0, 0, 0, 0, 0, 0xF0, 0xFF>>

  # Beyond REAL's range, the BEAM would make an infinity.
  defp float_bytes(x, 32) when is_number(x) and abs(x) > 3.402_823_466_385_288_6e38,
    do: raise(ArgumentError, "#{inspect(x)} is out of range for a REAL")

  defp float_bytes(x, bits) when is_number(x) do
    <<x::float-little-size(bits)>>
  rescue
    ArgumentError ->
      reraise ArgumentError,
              [message: "#{inspect(x)} is out of range for a float of #{bits} bits"],
              __STACKTRACE__
  end

  defp pad(bytes, n, unit, type) do
    if byte_size(bytes) > n * unit,
      do: raise(ArgumentError, "#{inspect(bytes)} is too long for #{inspect(type)}")

    bytes <> :binary.copy(<<0>>, (n + 1) * unit - byte_size(bytes))
  end

  defp array_bytes(type, [{first, last} | dims], values)
       when is_list(values) and length(values) == last - first + 1,
       do: for(value <- values, into: <<>>, do: array_bytes(type, dims, value))

  defp array_bytes(type, [], value), do: bytes(type, value)

  defp array_bytes(type, dims, values),
    do:
      raise(
        ArgumentError,
        "#{inspect(values)} doesn't fit an array #{inspect(dims)} of #{inspect(type)}"
      )

  # Members in order of their offsets, with zeros between them; bits set after.
  defp struct_bytes(size, members, map) do
    {bits, others} = values(members, map, :all) |> Enum.split_with(&match?({{_, _, :bit}, _}, &1))

    {parts, offset} =
      others
      |> Enum.sort_by(fn {{_name, offset, _type}, _value} -> offset end)
      |> Enum.map_reduce(0, fn {{name, offset, type}, value}, at ->
        if offset < at, do: raise(ArgumentError, "the member #{name} overlaps another")
        member = bytes(type, value)
        {[<<0::size((offset - at) * 8)>>, member], offset + byte_size(member)}
      end)

    bytes = IO.iodata_to_binary([parts, <<0::size((size - offset) * 8)>>])

    Enum.reduce(bits, bytes, fn {{_name, bit, :bit}, value}, bytes ->
      set_bit(bytes, bit, value)
    end)
  end

  defp set_bit(bytes, bit, value) when is_boolean(value) do
    <<before::binary-size(div(bit, 8)), byte, rest::binary>> = bytes
    mask = Bitwise.bsl(1, rem(bit, 8))
    byte = if value, do: Bitwise.bor(byte, mask), else: Bitwise.band(byte, Bitwise.bnot(mask))
    <<before::binary, byte, rest::binary>>
  end

  # Each member with its value from the map, found by name in upper or lower case alike, as the PLC
  # finds names; :all of them, or :some for a union.
  defp values(members, map, which) do
    given = Map.new(map, fn {key, value} -> {key |> to_string() |> String.downcase(), value} end)

    if map_size(given) < map_size(map),
      do: raise(ArgumentError, "members given twice: #{inspect(Map.keys(map))}")

    names = MapSet.new(members, fn {name, _, _} -> String.downcase(name) end)

    case Enum.reject(Map.keys(given), &MapSet.member?(names, &1)) do
      [] -> :ok
      unknown -> raise ArgumentError, "no such members: #{inspect(unknown)}"
    end

    Enum.flat_map(members, fn {name, _, _} = member ->
      case Map.fetch(given, String.downcase(name)) do
        {:ok, value} -> [{member, value}]
        :error when which == :all -> raise ArgumentError, "the member #{name} is missing"
        :error -> []
      end
    end)
  end
end
