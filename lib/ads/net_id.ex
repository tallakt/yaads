defmodule ADS.NetId do
  @moduledoc """
  AMS NetIds: six numbers from 0 to 255, written with dots like an IP address with two more parts,
  and sent as six bytes in that order.

      iex> ADS.NetId.parse("172.16.17.10.1.1")
      {:ok, <<172, 16, 17, 10, 1, 1>>}
      iex> ADS.NetId.to_string(<<5, 36, 69, 176, 1, 1>>)
      "5.36.69.176.1.1"
      iex> ADS.NetId.parse("10.0.0.5")
      :error

  A NetId is configured on each system, and is often its IP address with `.1.1` added, which
  `from_ip/1` makes.
  """

  @typedoc "A NetId as sent: six bytes."
  @type t :: <<_::48>>

  @doc "Parses a NetId written with dots."
  @spec parse(String.t()) :: {:ok, t} | :error
  def parse(string) when is_binary(string) do
    bytes = string |> String.split(".") |> Enum.map(&byte/1)

    if length(bytes) == 6 and Enum.all?(bytes, &is_integer/1),
      do: {:ok, :binary.list_to_bin(bytes)},
      else: :error
  end

  def parse(_other), do: :error

  # One to three digits, no sign: "1", "255", not "+1" or "0001".
  defp byte(part) when byte_size(part) in 1..3 do
    if part |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9)) do
      byte = String.to_integer(part)
      if byte <= 255, do: byte
    end
  end

  defp byte(_part), do: nil

  @doc "Parses a NetId, raising `ArgumentError` for one that isn't."
  @spec parse!(String.t()) :: t
  def parse!(string) do
    case parse(string) do
      {:ok, net_id} -> net_id
      :error -> raise ArgumentError, "a NetId is six numbers 0 to 255, got: #{inspect(string)}"
    end
  end

  @doc "A NetId written with dots."
  @spec to_string(t) :: String.t()
  def to_string(<<_::48>> = net_id),
    do: net_id |> :binary.bin_to_list() |> Enum.join(".")

  @doc """
  The NetId made from an IPv4 address by adding `.1.1`.

      iex> ADS.NetId.from_ip({10, 0, 0, 5})
      <<10, 0, 0, 5, 1, 1>>
  """
  @spec from_ip(:inet.ip4_address()) :: t
  def from_ip({a, b, c, d}), do: <<a, b, c, d, 1, 1>>
end
