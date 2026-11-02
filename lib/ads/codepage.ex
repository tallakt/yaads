defmodule ADS.Codepage.Encodings do
  @moduledoc false
  # The code pages yaads converts with, compiled in by Codepagex: those of Windows of one byte to
  # a character, and any the application adds with config :yaads, :codepages.

  @common [
    :ascii,
    :iso_8859_1,
    :windows_874,
    :windows_1250,
    :windows_1251,
    :windows_1252,
    :windows_1253,
    :windows_1254,
    :windows_1255,
    :windows_1256,
    :windows_1257,
    :windows_1258
  ]

  @extra Application.compile_env(:yaads, :codepages, [])

  use Codepagex.Backend, encodings: @common ++ @extra
end

defmodule ADS.Codepage do
  @moduledoc """
  The code page of the strings of one byte to a character a TwinCAT system has: its PLC's
  `STRING`s, the names and comments of its symbols and types, and the strings of its system
  service and router, such as its host name, routes and adapters. Windows-1252 unless told
  otherwise, with `codepage:` to `ADS.Client`, `ADS.Discovery` and the mix tasks, as Beckhoff's own
  libraries read them on Western Windows; a system on Windows of another language has that one's.

  [Codepagex](https://hex.pm/packages/codepagex) converts them. yaads has these compiled in:
  `:ascii`, `:iso_8859_1`, and Windows' code pages of one byte to a character, `:windows_874` and
  `:windows_1250` to `:windows_1258`. The application adds others in its config, by Codepagex's
  aliases or names, and recompiles yaads (`mix deps.compile yaads --force`):

      # config/config.exs
      config :yaads, :codepages, [:windows_932, "VENDORS/MICSFT/WINDOWS/CP949"]

  An encoding Codepagex itself has, as configured for the application, is taken too.

  What comes out is UTF-8, always: a byte the code page has no character for is `"\\uFFFD"`.
  """

  alias ADS.Codepage.Encodings

  @typedoc "An alias of Codepagex's, such as `:windows_1251`, or a full name."
  @type t :: atom | String.t()

  @default :windows_1252

  @doc "Windows-1252."
  @spec default() :: t
  def default, do: @default

  @doc "The code pages compiled into yaads, by Codepagex's full names."
  @spec available() :: [String.t()]
  def available, do: Encodings.encoding_list()

  @doc """
  The code page, if yaads or Codepagex has it; else an `ArgumentError` that says how to add it.

      iex> ADS.Codepage.check!(:windows_1251)
      :windows_1251
  """
  @spec check!(t) :: t
  def check!(codepage) do
    case convert(<<>>, codepage, &Encodings.to_string/2, &Codepagex.to_string/2) do
      {:ok, _} -> codepage
      {:error, _} -> raise ArgumentError, missing(codepage)
    end
  end

  @doc """
  A string from the code page, in UTF-8.

      iex> ADS.Codepage.decode(<<"Gr", 0xFC, 0xDF, "e ", 0x80>>)
      "Grüße €"
      iex> ADS.Codepage.decode(<<0xC0, 0xE1, 0x98>>, :windows_1251)
      "Аб�"
  """
  @spec decode(binary, t) :: String.t()
  def decode(bytes, codepage \\ @default) do
    replace = Codepagex.use_utf_replacement()

    case convert(
           bytes,
           codepage,
           &Encodings.to_string(&1, &2, replace),
           &Codepagex.to_string(&1, &2, replace)
         ) do
      {:ok, string, _replaced} -> string
      {:error, _reason, _acc} -> raise ArgumentError, missing(codepage)
    end
  end

  @doc """
  A string in the code page; `ArgumentError` for one with characters it doesn't have.

      iex> ADS.Codepage.encode!("Grüße €")
      <<"Gr", 0xFC, 0xDF, "e ", 0x80>>
  """
  @spec encode!(String.t(), t) :: binary
  def encode!(string, codepage \\ @default) when is_binary(string) do
    if not String.valid?(string), do: raise(ArgumentError, "not UTF-8: #{inspect(string)}")

    case convert(
           string,
           codepage,
           &Encodings.from_string/2,
           &Codepagex.from_string/2
         ) do
      {:ok, bytes} ->
        bytes

      {:error, "Unknown encoding" <> _} ->
        raise ArgumentError, missing(codepage)

      {:error, _} ->
        raise ArgumentError, "#{inspect(string)} has characters #{label(codepage)} doesn't"
    end
  end

  # With yaads' own code pages, or else Codepagex's.
  defp convert(data, codepage, own, codepagex) do
    case own.(data, codepage) do
      {:error, "Unknown encoding" <> _} -> codepagex.(data, codepage)
      {:error, "Unknown encoding" <> _, _acc} -> codepagex.(data, codepage)
      result -> result
    end
  end

  defp label(codepage) when is_atom(codepage),
    do: codepage |> Atom.to_string() |> String.replace("_", "-") |> String.capitalize()

  defp label(codepage), do: codepage

  defp missing(codepage) do
    "No code page #{inspect(codepage)}: add it to config :yaads, :codepages, and run " <>
      "mix deps.compile yaads --force; see ADS.Codepage"
  end
end
