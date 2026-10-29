defmodule ADS.TypeTest do
  use ExUnit.Case, async: true

  alias ADS.Type

  defp round_trip(type, value) do
    bytes = Type.encode(type, value)
    assert byte_size(bytes) == Type.size(type)
    assert Type.decode(type, bytes) == {:ok, value}
    bytes
  end

  test "integers, little-endian, of the size of their type, in range or not at all" do
    assert round_trip(:int, -2) == <<0xFE, 0xFF>>
    assert round_trip(:udint, 0xDEADBEEF) == <<0xEF, 0xBE, 0xAD, 0xDE>>
    assert round_trip(:lint, -0x8000000000000000) == <<0, 0, 0, 0, 0, 0, 0, 0x80>>
    assert round_trip(:ulint, 0xFFFFFFFFFFFFFFFF) == :binary.copy(<<0xFF>>, 8)
    round_trip(:sint, -128)
    round_trip(:usint, 255)
    round_trip(:byte, 255)
    round_trip(:word, 65535)
    round_trip(:dword, 0xFFFFFFFF)
    round_trip(:lword, 0)
    round_trip(:dint, -1)
    round_trip(:uint, 65535)

    for {type, value} <- [
          int: 32768,
          int: -32769,
          uint: -1,
          usint: 256,
          sint: 128,
          udint: 0x1_0000_0000,
          int: 1.5,
          int: "1"
        ] do
      assert_raise ArgumentError, fn -> Type.encode(type, value) end
    end
  end

  test "BOOL is a byte, true for anything but 0" do
    assert round_trip(:bool, true) == <<1>>
    assert round_trip(:bool, false) == <<0>>
    assert Type.decode(:bool, <<0x20>>) == {:ok, true}
    assert_raise ArgumentError, fn -> Type.encode(:bool, 1) end
  end

  test "REAL and LREAL, as IEEE 754, with infinities and NaN as atoms" do
    assert round_trip(:real, 1.5) == <<0, 0, 0xC0, 0x3F>>
    assert round_trip(:lreal, -2.25) == <<0, 0, 0, 0, 0, 0, 2, 0xC0>>

    for type <- [:real, :lreal],
        special <- [:nan, :infinity, :neg_infinity],
        do: round_trip(type, special)

    assert Type.decode(:real, <<1, 0, 0x80, 0x7F>>) == {:ok, :nan}
    assert Type.encode(:real, 2) == Type.encode(:real, 2.0)
    assert_raise ArgumentError, fn -> Type.encode(:real, 1.0e39) end
  end

  test "STRING(n) takes n + 1 bytes, in Latin-1, and ends at the first zero" do
    assert round_trip({:string, 5}, "Grüß") == <<"Gr", 0xFC, 0xDF, 0, 0>>
    assert Type.decode({:string, 5}, <<"ab", 0, "cd", 0>>) == {:ok, "ab"}
    # one without its zero still ends before it, at n characters, so that it can be written back
    assert Type.decode({:string, 2}, "abc") == {:ok, "ab"}
    assert Type.decode({:wstring, 1}, <<?a, 0, ?b, 0>>) == {:ok, "a"}
    assert_raise ArgumentError, fn -> Type.encode({:string, 3}, "toolong") end
    assert_raise ArgumentError, fn -> Type.encode({:string, 10}, "€") end
    assert Type.size({:string, 80}) == 81
  end

  test "a STRING with the attribute TcEncoding UTF-8 holds UTF-8, its bytes counted" do
    assert round_trip({:string, 6, :utf8}, "€uro") == "€uro" <> <<0>>
    assert_raise ArgumentError, fn -> Type.encode({:string, 3, :utf8}, "€uro") end
    assert Type.decode({:string, 3, :utf8}, <<0xFF, ?a, 0, 0>>) == {:ok, "�a"}
  end

  test "WSTRING(n) takes 2(n + 1) bytes, in UCS-2, which ends before U+10000" do
    assert round_trip({:wstring, 3}, "aé") == <<?a, 0, 0xE9, 0, 0, 0, 0, 0>>
    assert Type.decode({:wstring, 2}, <<?a, 0, 0, 0, ?b, 0>>) == {:ok, "a"}
    assert_raise ArgumentError, fn -> Type.encode({:wstring, 4}, "😀") end
    assert_raise ArgumentError, fn -> Type.encode({:wstring, 1}, "ab") end
    # a surrogate from a device is replaced, alone or in a pair, as UCS-2 has none
    assert Type.decode({:wstring, 1}, <<0x00, 0xD8, 0, 0>>) == {:ok, "�"}
    assert Type.decode({:wstring, 2}, <<0x3D, 0xD8, 0x00, 0xDE, 0, 0>>) == {:ok, "��"}
  end

  test "TIME in ms, LTIME in ns, as integers" do
    # T#1d2h30m40s500ms and LTIME#100d2h30m40s500ms600us700ns, the manual's samples
    ms = ((24 + 2) * 3600 + 30 * 60 + 40) * 1000 + 500
    assert round_trip(:time, ms) == <<ms::32-little>>
    ns = ((100 * 24 + 2) * 3600 + 30 * 60 + 40) * 1_000_000_000 + 500_600_700
    assert round_trip(:ltime, ns) == <<ns::64-little>>
    assert_raise ArgumentError, fn -> Type.encode(:time, -1) end
  end

  test "DATE and DATE_AND_TIME in seconds since 1970, TIME_OF_DAY in ms" do
    date = DateTime.to_unix(~U[2026-02-07 00:00:00Z])
    assert round_trip(:date, ~D[2026-02-07]) == <<date::32-little>>
    stamp = DateTime.to_unix(~U[2026-02-07 12:55:01Z])
    assert round_trip(:date_and_time, ~N[2026-02-07 12:55:01]) == <<stamp::32-little>>
    ms = (12 * 3600 + 3 * 60 + 4) * 1000 + 567
    assert round_trip(:time_of_day, ~T[12:03:04.567]) == <<ms::32-little>>

    assert Type.decode(:date_and_time, <<0xFF, 0xFF, 0xFF, 0xFF>>) ==
             {:ok, ~N[2106-02-07 06:28:15]}

    # past midnight, which bytes can hold and a PLC doesn't make
    assert Type.decode(:time_of_day, <<0x00, 0x5C, 0x26, 0x05>>) == {:ok, 86_400_000}

    assert Type.encode(:date_and_time, ~U[2026-02-07 12:55:01Z]) ==
             Type.encode(:date_and_time, ~N[2026-02-07 12:55:01])

    assert_raise ArgumentError, fn -> Type.encode(:date, ~D[1969-12-31]) end
  end

  test "LDATE, LDATE_AND_TIME and LTIME_OF_DAY in ns, keeping microseconds" do
    round_trip(:ldate_and_time, ~N[2026-02-07 12:55:01.234567])
    round_trip(:ltime_of_day, ~T[12:03:04.567890])
    round_trip(:ldate, ~D[2262-04-11])

    # the bounds TwinCAT gives, a signed 64-bit number
    assert Type.decode(:ldate_and_time, <<0, 0, 0, 0, 0, 0, 0, 0x80>>) ==
             {:ok, ~N[1677-09-21 00:12:43.145224]}

    assert Type.decode(:ldate_and_time, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F>>) ==
             {:ok, ~N[2262-04-11 23:47:16.854775]}

    assert Type.encode(:ltime_of_day, 1) == <<1, 0, 0, 0, 0, 0, 0, 0>>
  end

  test "arrays, a list for each dimension" do
    type = {:array, :int, [{1, 2}, {-1, 1}]}
    assert Type.size(type) == 12
    bytes = round_trip(type, [[1, 2, 3], [4, 5, 6]])
    assert bytes == <<1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0>>
    assert_raise ArgumentError, fn -> Type.encode(type, [[1, 2, 3]]) end
    assert_raise ArgumentError, fn -> Type.encode(type, [[1, 2], [3, 4]]) end
  end

  # The alignment page of the TwinCAT 3 PLC manual: three structures of the same members.
  test "TwinCAT 3 aligns each member to its size, up to 8 bytes, and pads the structure" do
    assert {:struct, 16, [{"fVar", 0, :lreal}, {"nVar1", 8, :dint}, {"nVar2", 12, :sint}]} =
             Type.layout([{"fVar", :lreal}, {"nVar1", :dint}, {"nVar2", :sint}])

    assert {:struct, 16, [{"nVar2", 0, :sint}, {"nVar1", 4, :dint}, {"fVar", 8, :lreal}]} =
             Type.layout([{"nVar2", :sint}, {"nVar1", :dint}, {"fVar", :lreal}])

    assert {:struct, 24, [{"nVar2", 0, :sint}, {"fVar", 8, :lreal}, {"nVar1", 16, :dint}]} =
             Type.layout([{"nVar2", :sint}, {"fVar", :lreal}, {"nVar1", :dint}])

    # "On a system with 1-byte alignment the three structures would have the same memory
    # requirement of 13 bytes."
    for members <- [
          [{"fVar", :lreal}, {"nVar1", :dint}, {"nVar2", :sint}],
          [{"nVar2", :sint}, {"nVar1", :dint}, {"fVar", :lreal}],
          [{"nVar2", :sint}, {"fVar", :lreal}, {"nVar1", :dint}]
        ],
        do: assert({:struct, 13, _} = Type.layout(members, pack_mode: 1))

    assert {:struct, 12, [_, {"nLWORD", 4, :lword}]} =
             Type.layout([{"nDWORD", :dword}, {"nLWORD", :lword}], pack_mode: 4)

    assert {:struct, 16, [_, {"nLWORD", 8, :lword}]} =
             Type.layout([{"nDWORD", :dword}, {"nLWORD", :lword}])
  end

  # The pack_mode attribute's page: two structures, laid out in each mode.
  test "pack_mode moves members as the PLC manual's tables show" do
    members = [
      {"Var1", :bool},
      {"Var2", :byte},
      {"Var3", :word},
      {"Var4", :byte},
      {"Var5", :dword},
      {"Var6", :byte},
      {"Var7", :byte},
      {"Var8", :dword}
    ]

    offsets = fn pack ->
      Type.layout(members, pack_mode: pack) |> elem(2) |> Enum.map(&elem(&1, 1))
    end

    assert offsets.(0) == [0, 1, 2, 4, 5, 9, 10, 11]
    assert offsets.(1) == [0, 1, 2, 4, 5, 9, 10, 11]
    assert offsets.(2) == [0, 1, 2, 4, 6, 10, 11, 12]
    assert offsets.(4) == [0, 1, 2, 4, 8, 12, 13, 16]
    assert offsets.(8) == [0, 1, 2, 4, 8, 12, 13, 16]
    assert {:struct, 15, _} = Type.layout(members, pack_mode: 1)
    assert {:struct, 16, _} = Type.layout(members, pack_mode: 2)
    assert {:struct, 20, _} = Type.layout(members, pack_mode: 8)

    members = [
      {"Var1", :byte},
      {"Var2", :lword},
      {"Var3", :byte},
      {"Var4", :byte},
      {"Var5", :dword},
      {"Var6", :byte},
      {"Var7", :byte},
      {"Var8", :word}
    ]

    offsets = fn pack ->
      Type.layout(members, pack_mode: pack) |> elem(2) |> Enum.map(&elem(&1, 1))
    end

    assert offsets.(1) == [0, 1, 9, 10, 11, 15, 16, 17]
    assert offsets.(2) == [0, 2, 10, 11, 12, 16, 17, 18]
    assert offsets.(4) == [0, 4, 12, 13, 16, 20, 21, 22]
    assert offsets.(8) == [0, 8, 16, 17, 20, 24, 25, 26]
    # an array of them stays aligned
    assert {:struct, 32, _} = Type.layout(members)
  end

  test "strings anywhere, nested structures by their largest member, bits together in bytes" do
    inner = Type.layout([{"a", :sint}, {"b", :dint}])

    assert {:struct, 20, [{"s", 0, {:string, 5}}, {"inner", 8, ^inner}, {"x", 16, :sint}]} =
             Type.layout([{"s", {:string, 5}}, {"inner", inner}, {"x", :sint}])

    assert {:struct, 3, [{"b0", 0, :bit}, {"b1", 1, :bit}, {"n", 1, :byte}, {"b2", 16, :bit}]} =
             Type.layout([{"b0", :bit}, {"b1", :bit}, {"n", :byte}, {"b2", :bit}])

    assert_raise ArgumentError, fn -> Type.layout([{"x", :int}], pack_mode: 3) end
    assert_raise ArgumentError, fn -> Type.layout([{"x", :nope}]) end
  end

  test "structures are maps of their members, all of them to write, by name in any case" do
    type = Type.layout([{"nSpeed", :int}, {"fTemp", :lreal}, {"sTag", {:string, 3}}])
    value = %{"nSpeed" => 1500, "fTemp" => 21.5, "sTag" => "P1"}
    round_trip(type, value)
    assert Type.encode(type, %{nspeed: 1500, FTEMP: 21.5, sTag: "P1"}) == Type.encode(type, value)
    assert_raise ArgumentError, ~r/missing/, fn -> Type.encode(type, %{"nSpeed" => 1}) end

    assert_raise ArgumentError, ~r/no such/, fn ->
      Type.encode(type, Map.put(value, "nOther", 1))
    end

    assert_raise ArgumentError, ~r/twice/, fn ->
      Type.encode(type, Map.merge(value, %{nSpeed: 1}))
    end
  end

  test "BIT members, each a bit of the structure, the lowest first" do
    type = {:struct, 2, [{"bA", 0, :bit}, {"bB", 1, :bit}, {"nRest", 1, :byte}]}
    assert round_trip(type, %{"bA" => true, "bB" => false, "nRest" => 9}) == <<1, 9>>
    assert Type.decode(type, <<2, 0>>) == {:ok, %{"bA" => false, "bB" => true, "nRest" => 0}}
  end

  test "a union is every member read from the same bytes, and one member written" do
    type = {:union, 8, [{"fA", 0, :lreal}, {"nB", 0, :lint}, {"nC", 0, :word}]}
    bytes = Type.encode(type, %{"fA" => 1.0})

    assert Type.decode(type, bytes) ==
             {:ok, %{"fA" => 1.0, "nB" => 0x3FF0000000000000, "nC" => 0}}

    assert_raise ArgumentError, fn -> Type.encode(type, %{"fA" => 1.0, "nC" => 2}) end
  end

  test "an enumeration is the name of its value, or the number of one without" do
    type = {:enum, :int, [{"eRed", 0}, {"eGreen", 10}]}
    assert round_trip(type, "eGreen") == <<10, 0>>
    assert Type.decode(type, <<11, 0>>) == {:ok, 11}
    assert Type.encode(type, "EGREEN") == <<10, 0>>
    assert Type.encode(type, 3) == <<3, 0>>
    assert_raise ArgumentError, fn -> Type.encode(type, "eBlue") end
  end

  test "raw bytes, and the wrong number of them" do
    assert round_trip({:raw, 3}, <<1, 2, 3>>) == <<1, 2, 3>>
    assert Type.decode(:int, <<1>>) == :error
    assert_raise ArgumentError, fn -> Type.encode({:raw, 3}, <<1>>) end
  end

  test "type names TwinCAT has built in" do
    assert Type.parse("INT") == {:ok, :int}
    assert Type.parse(" lreal ") == {:ok, :lreal}
    assert Type.parse("DT") == {:ok, :date_and_time}
    assert Type.parse("TOD") == {:ok, :time_of_day}
    assert Type.parse("LDT") == {:ok, :ldate_and_time}
    assert Type.parse("STRING") == {:ok, {:string, 80}}
    assert Type.parse("STRING[30]") == {:ok, {:string, 30}}
    assert Type.parse("WSTRING(10)") == {:ok, {:wstring, 10}}
    assert Type.parse("ARRAY [0..9] OF STRING(20)") == {:ok, {:array, {:string, 20}, [{0, 9}]}}

    assert Type.parse("ARRAY [0..1] OF ARRAY [1..2] OF BOOL") ==
             {:ok, {:array, {:array, :bool, [{1, 2}]}, [{0, 1}]}}

    # a dimension in brackets of its own, as Beckhoff's .NET libraries have it, and nothing else
    # between the brackets and OF, a character that's longer in upper case, as ɐ is, included
    assert Type.parse("ARRAY [0..2][1..2] OF DINT", 24) ==
             {:ok, {:array, :dint, [{0, 2}, {1, 2}]}}

    assert Type.parse("ARRAY [0..2] [1..2] OF DINT") == {:ok, {:array, :dint, [{0, 2}, {1, 2}]}}
    assert Type.parse("ARRAY [0..1]ɐɐɐɐɐɐ OF INT") == :error
    assert Type.parse("ARRAY [0..2][1..2 OF DINT") == :error
    assert Type.parse("INT (0..100)") == {:ok, :int}
    assert Type.parse("XINT", 4) == {:ok, :dint}
    assert Type.parse("PVOID", 8) == {:ok, :ulint}
    assert Type.parse("REFERENCE TO ST_Pump", 8) == {:ok, :ulint}
    assert Type.parse("POINTER TO INT") == :error
    assert Type.parse("ARRAY [0..9] OF ST_Pump") == :error
    assert Type.parse("ARRAY [9..0] OF INT") == :error
    assert Type.parse("STRINGS") == :error
    assert Type.parse("E_Mode") == :error
  end

  test "types by data type id, and their names" do
    assert Type.id_name(65) == :big_type
    assert Type.id_name(99) == 99
    assert Type.from_id(2, 2) == :int
    assert Type.from_id(:uint64, 8) == :ulint
    assert Type.from_id(:int16, 4) == nil
    assert Type.from_id(:wstring, 22) == {:wstring, 10}
    assert Type.from_id(99, 4) == nil
  end

  test "what isn't a type" do
    for type <- [
          :nope,
          {:string, -1},
          {:array, :int, []},
          {:array, :int, [{2, 1}]},
          {:struct, 2, [{"a", 1, :int}]},
          {:enum, :real, []},
          {:raw, -1}
        ] do
      assert_raise ArgumentError, fn -> Type.check!(type) end
    end

    assert Type.check!({:struct, 2, [{"a", 0, :int}]}) == {:struct, 2, [{"a", 0, :int}]}
  end
end
