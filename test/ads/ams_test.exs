defmodule ADS.AMSTest do
  use ExUnit.Case, async: true

  alias ADS.{AMS, NetId}

  @plc <<5, 36, 69, 176, 1, 1>>
  @client <<192, 168, 0, 1, 1, 1>>

  defp packet(fields \\ []) do
    struct(
      %AMS{target: @plc, target_port: 851, source: @client, source_port: 32905, command: 2},
      fields
    )
  end

  test "the AMS/TCP header, then the AMS header, as the spec lays them out" do
    frame = AMS.encode(packet(command: 4, invoke_id: 0x01020304))

    # reserved, length of the AMS header and data
    assert <<0, 0, 32, 0, 0, 0, ams::binary>> = frame

    assert ams ==
             <<5, 36, 69, 176, 1, 1, 0x53, 0x03>> <>
               <<192, 168, 0, 1, 1, 1, 0x89, 0x80>> <>
               <<4, 0, 4, 0>> <>
               <<0, 0, 0, 0>> <>
               <<0, 0, 0, 0>> <>
               <<4, 3, 2, 1>>
  end

  test "the data follows the header, and both lengths count it" do
    frame = AMS.encode(packet(data: <<1, 2, 3>>, error_code: 0x710, state_flags: 5))

    assert <<0, 0, 35, 0, 0, 0, _addresses::binary-16, 2, 0, 5, 0, 3, 0, 0, 0, 0x10, 7, 0, 0,
             _invoke::binary-4, 1, 2, 3>> = frame
  end

  test "inside Secure ADS, without the AMS/TCP header" do
    tls = AMS.encode(packet(data: "abc"), :tls)
    tcp = AMS.encode(packet(data: "abc"), :tcp)
    assert tcp == <<0, 0, 35, 0, 0, 0>> <> tls
    assert {:ok, %AMS{data: "abc"}, "rest"} = AMS.decode(tls <> "rest", :tls)
  end

  test "a frame split anywhere comes back whole, and what follows it is left" do
    frame = AMS.encode(packet(data: :binary.copy("x", 40), invoke_id: 7))

    for framing <- [:tcp, :tls] do
      frame = AMS.encode(packet(data: :binary.copy("x", 40), invoke_id: 7), framing)

      for at <- 0..(byte_size(frame) - 1) do
        assert AMS.decode(binary_part(frame, 0, at), framing) == :more
      end

      assert {:ok, %AMS{invoke_id: 7}, "next"} = AMS.decode(frame <> "next", framing)
    end

    assert {:ok, decoded, ""} = AMS.decode(frame)
    assert decoded == packet(data: :binary.copy("x", 40), invoke_id: 7)
  end

  test "a request and a response are told apart by the first bit of the state flags" do
    refute AMS.response?(packet())
    assert AMS.response?(packet(state_flags: AMS.response_flags()))
    assert AMS.request_flags() == 0x0004
    assert AMS.response_flags() == 0x0005
  end

  test "a frame with reserved bytes other than 0 isn't AMS, and is passed over" do
    other = <<0x10, 0, 4, 0, 0, 0, 1, 2, 3, 4>>
    assert AMS.decode(other <> "next") == {:discard, "next"}
  end

  test "an AMS header whose data length disagrees with the AMS/TCP header's is passed over" do
    <<head::binary-26, _length::32, tail::binary>> = AMS.encode(packet(data: "abcd"))

    assert AMS.decode(<<head::binary, 3::32-little, tail::binary>> <> "next") ==
             {:discard, "next"}
  end

  test "a length no AMS packet has, or past the limit, can't be read past" do
    assert AMS.decode(<<0, 0, 31, 0, 0, 0>> <> :binary.copy(<<0>>, 31)) ==
             {:error, :invalid_length}

    assert AMS.decode(<<0, 0, 0xFF, 0xFF, 0xFF, 0xFF>>) == {:error, :invalid_length}
    assert AMS.decode(AMS.encode(packet(data: "12345")), :tcp, 4) == {:error, :invalid_length}

    assert AMS.decode(AMS.encode(packet(data: "12345"), :tls), :tls, 4) ==
             {:error, :invalid_length}

    assert {:ok, _, ""} = AMS.decode(AMS.encode(packet(data: "12345")), :tcp, 5)
  end

  test "NetIds" do
    assert NetId.parse("5.36.69.176.1.1") == {:ok, @plc}
    assert NetId.to_string(@plc) == "5.36.69.176.1.1"

    for bad <- [
          "",
          "1.2.3.4.5",
          "1.2.3.4.5.6.7",
          "1.2.3.4.5.256",
          "1.2.3.4.5.-1",
          "1.2.3.4.5.+1",
          "1.2.3.4.5.0001",
          "a.b.c.d.e.f",
          "1..3.4.5.6"
        ] do
      assert NetId.parse(bad) == :error, bad
    end

    assert_raise ArgumentError, fn -> NetId.parse!("10.0.0.5") end
  end
end
