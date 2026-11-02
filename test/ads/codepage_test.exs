defmodule ADS.CodepageTest do
  use ExUnit.Case, async: true

  alias ADS.Codepage

  test "Windows' code pages of one byte to a character are compiled in" do
    for n <- [874 | Enum.to_list(1250..1258)],
        do: assert("VENDORS/MICSFT/WINDOWS/CP#{n}" in Codepage.available())

    assert Codepage.default() == :windows_1252
  end

  test "strings to and from a code page, by alias or full name" do
    assert Codepage.decode(<<"Gr", 0xFC, 0xDF, "e ", 0x80, 0x9F>>) == "Grüße €Ÿ"
    assert Codepage.encode!("Grüße €") == <<"Gr", 0xFC, 0xDF, "e ", 0x80>>
    assert Codepage.decode(<<0xCE, 0xEA>>, "VENDORS/MICSFT/WINDOWS/CP1251") == "Ок"
    assert Codepage.encode!("Ł", :windows_1250) == <<0xA3>>
  end

  test "UTF-8 out, always; what a code page doesn't have, in, an ArgumentError" do
    assert Codepage.decode(<<0x81, ?a, 0x8D>>) == "�a�"

    assert_raise ArgumentError, ~r/"Ω" has characters Windows-1252 doesn't/, fn ->
      Codepage.encode!("Ω")
    end

    assert_raise ArgumentError, ~r/not UTF-8/, fn -> Codepage.encode!(<<0xFF>>) end
  end

  test "an encoding of Codepagex's own is taken too, and one neither has is an error" do
    # ISO 8859-5 isn't yaads', but Codepagex has it as configured
    refute "ISO8859/8859-5" in Codepage.available()
    assert Codepage.check!(:iso_8859_5) == :iso_8859_5
    assert Codepage.decode(<<0xB0>>, :iso_8859_5) == "А"
    assert Codepage.encode!("А", :iso_8859_5) == <<0xB0>>

    for call <- [
          fn -> Codepage.check!(:windows_932) end,
          fn -> Codepage.decode("a", :windows_932) end,
          fn -> Codepage.encode!("a", :windows_932) end
        ] do
      assert_raise ArgumentError, ~r/No code page :windows_932: add it to config :yaads/, call
    end
  end
end
