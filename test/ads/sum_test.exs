defmodule ADS.SumTest do
  use ExUnit.Case, async: true

  alias ADS.Sum

  # The sum commands of the spec's table of system services, each an ADS Read Write.

  test "reads: each index group, offset and length; the return codes, then the data" do
    reads = [{0x4020, 0, 2}, {0xF005, 9, 4}]

    assert Sum.read(reads) ==
             {:read_write, 0xF080, 2, 8 + 6,
              <<0x20, 0x40, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 5, 0xF0, 0, 0, 9, 0, 0, 0, 4, 0, 0, 0>>}

    assert Sum.decode_read(reads, <<0::32, 0::32, 1, 2, 3, 4, 5, 6>>) ==
             {:ok, [{:ok, <<1, 2>>}, {:ok, <<3, 4, 5, 6>>}]}
  end

  test "reads that fail come back as their return codes, with or without zeros in place of the data" do
    reads = [{0x4020, 0, 2}, {0xF005, 9, 4}]
    with_zeros = <<0x710::32-little, 0::32, 0, 0, 3, 4, 5, 6>>
    without = <<0x710::32-little, 0::32, 3, 4, 5, 6>>
    expected = {:ok, [{:error, :device_symbol_not_found}, {:ok, <<3, 4, 5, 6>>}]}
    assert Sum.decode_read(reads, with_zeros) == expected
    assert Sum.decode_read(reads, without) == expected

    assert Sum.decode_read(reads, <<0::32, 0::32, 1>>) ==
             {:error, {:invalid_response, <<0::32, 0::32, 1>>}}
  end

  test "writes: each index group, offset and length, then the data; the return codes" do
    writes = [{0x4020, 0, <<1, 2>>}, {0x4020, 8, <<3>>}]

    assert Sum.write(writes) ==
             {:read_write, 0xF081, 2, 8,
              <<0x20, 0x40, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0x20, 0x40, 0, 0, 8, 0, 0, 0, 1, 0, 0,
                0, 1, 2, 3>>}

    assert Sum.decode_write(writes, <<0::32, 0x703::32-little>>) ==
             {:ok, [:ok, {:error, :device_invalid_offset}]}

    assert Sum.decode_write(writes, <<0::32>>) == {:error, {:invalid_response, <<0::32>>}}
  end

  test "read-writes, as for two handles at once: 24 bytes back, two codes and lengths, two handles" do
    items = [{0xF003, 0, 4, ".bVar01\0"}, {0xF003, 0, 4, ".bVar02\0"}]
    assert {:read_write, 0xF082, 2, 0x18, data} = Sum.read_write(items)

    assert data ==
             <<3, 0xF0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 8, 0, 0, 0>> <>
               <<3, 0xF0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 8, 0, 0, 0>> <> ".bVar01\0.bVar02\0"

    answer = <<0::32, 4::32-little, 0x710::32-little, 0::32, 42::32-little>>

    assert Sum.decode_read_write(items, answer) ==
             {:ok, [{:ok, <<42, 0, 0, 0>>}, {:error, :device_symbol_not_found}]}

    assert Sum.decode_read_write(items, <<0::32>>) == {:error, {:invalid_response, <<0::32>>}}
  end

  test "500 at most, and numbers of 32 bits" do
    assert Sum.max() == 500
    assert_raise ArgumentError, fn -> Sum.read([{0x1_0000_0000, 0, 1}]) end
  end
end
