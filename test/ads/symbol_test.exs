defmodule ADS.SymbolTest do
  use ExUnit.Case, async: true

  alias ADS.{DataType, Symbol}

  # Entries written out field by field, as ADS.Symbol and ADS.DataType describe them, and padded
  # to their length.
  defp entry(body, pad) do
    <<4 + byte_size(body) + pad::32-little, body::binary, 0::size(pad * 8)>>
  end

  defp symbol(name, type, opts \\ []) do
    comment = Keyword.get(opts, :comment, "")
    flags = Keyword.get(opts, :flags, 0)
    extra = Keyword.get(opts, :extra, <<>>)

    entry(
      <<0x4040::32-little, 16::32-little, 2::32-little, 2::32-little, flags::32-little,
        byte_size(name)::16-little, byte_size(type)::16-little, byte_size(comment)::16-little,
        name::binary, 0, type::binary, 0, comment::binary, 0, extra::binary>>,
      Keyword.get(opts, :pad, 0)
    )
  end

  test "a symbol: address, size, data type, flags, then its name, type and comment" do
    assert {:ok, symbol} = Symbol.decode(symbol("MAIN.nSpeed", "INT", comment: "rpm", pad: 3))

    assert symbol == %Symbol{
             name: "MAIN.nSpeed",
             type: "INT",
             index_group: 0x4040,
             index_offset: 16,
             size: 2,
             data_type: :int16,
             flags: 0,
             comment: "rpm"
           }
  end

  test "its type's GUID and its attributes, when its flags say they follow" do
    guid = <<0x12345678::32-little, 0x9ABC::16-little, 0xDEF0::16-little, 1, 2, 3, 4, 5, 6, 7, 8>>
    attributes = <<2::16-little, 10, 5, "TcEncoding", 0, "UTF-8", 0, 4, 0, "hide", 0, 0>>

    assert {:ok, symbol} =
             Symbol.decode(
               symbol("GVL.s", "STRING(20)",
                 flags: 0x1008 + 0x20,
                 extra: guid <> attributes,
                 pad: 2
               )
             )

    assert symbol.guid == "12345678-9ABC-DEF0-0102-030405060708"
    assert symbol.attributes == %{"TcEncoding" => "UTF-8", "hide" => ""}
    assert Symbol.flags(symbol) == [:type_guid, :read_only, :attributes]
  end

  test "names in UTF-8 if they are, else in Latin-1" do
    assert {:ok, %{comment: "Grüße"}} = Symbol.decode(symbol("a", "INT", comment: "Grüße"))

    assert {:ok, %{comment: "Grüße"}} =
             Symbol.decode(symbol("a", "INT", comment: <<"Gr", 0xFC, 0xDF, "e">>))
  end

  test "an upload is entries one after another" do
    upload =
      symbol("MAIN.a", "INT", pad: 1) <>
        symbol("MAIN.b", "BOOL") <> symbol("MAIN.c", "LREAL", pad: 7)

    assert {:ok, [%{name: "MAIN.a"}, %{name: "MAIN.b"}, %{name: "MAIN.c"}]} =
             Symbol.decode_all(upload)

    assert Symbol.decode_all(<<>>) == {:ok, []}
  end

  test "an entry that isn't one" do
    good = symbol("MAIN.a", "INT")
    assert Symbol.decode(binary_part(good, 0, byte_size(good) - 1)) == :error
    assert Symbol.decode(<<10::32-little, 0::48>>) == :error
    # lengths of strings past the entry's end
    <<head::binary-28, _::16, tail::binary>> = good
    assert Symbol.decode(<<head::binary, 200::16-little, tail::binary>>) == :error
    assert Symbol.decode_all(good <> <<1, 2>>) == :error
  end

  defp data_type(name, type, size, offset, id, opts \\ []) do
    flags = Keyword.get(opts, :flags, 0)
    array = Keyword.get(opts, :array, [])
    members = Keyword.get(opts, :members, [])

    entry(
      <<1::32-little, 0::32, 0::32, size::32-little, offset::32-little, id::32-little,
        flags::32-little, byte_size(name)::16-little, byte_size(type)::16-little, 0::16,
        length(array)::16-little, length(members)::16-little, name::binary, 0, type::binary, 0,
        0>> <>
        for({first, n} <- array, into: <<>>, do: <<first::signed-32-little, n::32-little>>) <>
        IO.iodata_to_binary(members) <> Keyword.get(opts, :extra, <<>>),
      Keyword.get(opts, :pad, 0)
    )
  end

  defp resolve_none(_name, _size), do: :error

  test "a structure: its members, entries of their own, at their offsets" do
    bytes =
      data_type("ST_Pump", "", 16, 0, 65,
        members: [
          data_type("nSpeed", "INT", 2, 0, 2, pad: 1),
          data_type("fTemp", "LREAL", 8, 8, 5)
        ],
        pad: 4
      )

    assert {:ok, pump} = DataType.decode(bytes)
    assert pump.name == "ST_Pump"

    assert [
             %DataType{name: "nSpeed", type: "INT", offset: 0},
             %DataType{name: "fTemp", offset: 8, data_type: :real64}
           ] = pump.members

    assert DataType.to_type(pump, &resolve_none/2) ==
             {:struct, 16, [{"nSpeed", 0, :int}, {"fTemp", 8, :lreal}]}
  end

  test "an enumeration: its values after the members, as many bytes each as the type" do
    values =
      <<3::16-little, 4, "eOff", 0, 0::16-little, 5, "eAuto", 0, 1::16-little, 3, "eNo", 0,
        0xFFFF::16-little>>

    assert {:ok, mode} =
             DataType.decode(data_type("E_Mode", "INT", 2, 0, 2, flags: 0x2000, extra: values))

    assert mode.enum == [{"eOff", 0}, {"eAuto", 1}, {"eNo", -1}]

    assert DataType.to_type(mode, &resolve_none/2) ==
             {:enum, :int, [{"eOff", 0}, {"eAuto", 1}, {"eNo", -1}]}
  end

  test "what follows the members, in order, each when flagged: GUID, copy mask, methods, attributes" do
    guid = :binary.copy(<<7>>, 16)
    mask = <<0xFF, 0xFF>>
    methods = <<2::16-little, 8::32-little, 0::32, 6::32-little, 0::16>>
    attributes = <<1::16-little, 4, 1, "pack", 0, "1", 0>>

    assert {:ok, t} =
             DataType.decode(
               data_type("T", "INT", 2, 0, 2,
                 flags: 0x80 + 0x200 + 0x800 + 0x1000,
                 extra: guid <> mask <> methods <> attributes
               )
             )

    assert t.guid == "07070707-0707-0707-0707-070707070707"
    assert t.attributes == %{"pack" => "1"}
  end

  test "what follows the members and doesn't parse is left out, and the rest kept" do
    assert {:ok, t} =
             DataType.decode(
               data_type("T", "INT", 2, 0, 2, flags: 0x1000 + 0x2000, extra: <<9::16-little, 1>>)
             )

    assert t.attributes == %{} and t.enum == []
    assert t.name == "T"
  end

  test "an array: its dimensions, each its first index and number of elements" do
    assert {:ok, array} =
             DataType.decode(data_type("ARRAY [0..1] OF ST_X", "ST_X", 8, 0, 65, array: [{0, 2}]))

    assert array.array == [{0, 2}]

    resolve = fn
      "ST_X", 4 -> {:ok, {:struct, 4, [{"n", 0, :dint}]}}
      _name, _size -> :error
    end

    assert DataType.to_type(array, resolve) == {:array, {:struct, 4, [{"n", 0, :dint}]}, [{0, 1}]}

    assert {:ok, ints} =
             DataType.decode(
               data_type("ARRAY [-1..1, 1..2] OF INT", "INT", 12, 0, 2, array: [{-1, 3}, {1, 2}])
             )

    assert DataType.to_type(ints, &resolve_none/2) == {:array, :int, [{-1, 1}, {1, 2}]}
  end

  test "another name for a type, as T_MaxString is for STRING(255)" do
    assert {:ok, alias} = DataType.decode(data_type("T_MaxString", "STRING(255)", 256, 0, 30))
    assert DataType.to_type(alias, &resolve_none/2) == {:string, 255}
  end

  test "members whose types are described elsewhere, BIT members, and unions" do
    members = [
      data_type("bA", "BIT", 1, 0, 33, flags: 0x22),
      data_type("bB", "BIT", 1, 1, 33, flags: 0x22),
      data_type("eMode", "E_Mode", 2, 2, 2)
    ]

    assert {:ok, t} = DataType.decode(data_type("ST_Flags", "", 4, 0, 65, members: members))

    resolve = fn
      "E_Mode", 2 -> {:ok, {:enum, :int, [{"eOff", 0}]}}
      _name, _size -> :error
    end

    assert DataType.to_type(t, resolve) ==
             {:struct, 4,
              [{"bA", 0, :bit}, {"bB", 1, :bit}, {"eMode", 2, {:enum, :int, [{"eOff", 0}]}}]}

    union =
      data_type("U", "", 8, 0, 65,
        members: [data_type("f", "LREAL", 8, 0, 5), data_type("n", "WORD", 2, 0, 18)]
      )

    assert {:ok, u} = DataType.decode(union)

    assert DataType.to_type(u, &resolve_none/2) ==
             {:union, 8, [{"f", 0, :lreal}, {"n", 0, :word}]}
  end

  test "what can't be made out is bytes, so that the rest still decode" do
    members = [data_type("p", "I_Unknown", 8, 0, 65), data_type("n", "INT", 2, 8, 2)]
    assert {:ok, t} = DataType.decode(data_type("ST", "", 16, 0, 65, members: members))

    assert DataType.to_type(t, &resolve_none/2) ==
             {:struct, 16, [{"p", 0, {:raw, 8}}, {"n", 8, :int}]}

    # a member past the end of its structure makes the structure bytes
    members = [data_type("n", "DINT", 4, 6, 3)]
    assert {:ok, t} = DataType.decode(data_type("ST", "", 8, 0, 65, members: members))
    assert DataType.to_type(t, &resolve_none/2) == {:raw, 8}
  end

  test "data types nested past any sense stop being read" do
    deep =
      Enum.reduce(1..40, data_type("x", "INT", 2, 0, 2), fn _, inner ->
        data_type("s", "", 2, 0, 65, members: [inner])
      end)

    assert DataType.decode(deep) == :error

    assert DataType.decode_all(data_type("a", "INT", 2, 0, 2) <> data_type("b", "BOOL", 1, 0, 33))
           |> elem(1)
           |> length() == 2
  end
end
