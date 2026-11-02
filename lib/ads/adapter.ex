defmodule ADS.Adapter do
  @moduledoc """
  A network adapter of a TwinCAT system, as its system service lists them, for
  `ADS.Client.adapters/2`: index group 701, `SYSTEMSERVICE_IPHELPERAPI` in Beckhoff's
  Tc2_Utilities, offset 1, `IPHELPERAPI_ADAPTERSINFO`, on AMS port 10000. A read of 4 bytes
  answers the size of the whole list; a read of less than that, `:device_invalid_size`.

  Beckhoff doesn't document how the list comes; this is as TwinCAT 3.1 4026 answers. It is the
  `IP_ADAPTER_INFO` of Windows' `GetAdaptersInfo`, as Microsoft documents it, laid out as a
  32-bit program has it, with a 64-bit `time_t`: 648 bytes for each adapter, each pointer an offset
  from the start of the list. All numbers are little-endian:

  | Bytes | Field |
  |---|---|
  | 4 | the offset of the next adapter, 0 after the last |
  | 4 | a combined index |
  | 260 | its name, with a zero after |
  | 132 | its description, with a zero after |
  | 4, 8 | the length of its hardware address, and the address |
  | 4 | its index |
  | 4 | its type, as `MIB_IF_TYPE_*` in Windows (see `t:type/0`) |
  | 4 | whether DHCP is enabled |
  | 4 | a pointer, 0 |
  | 40 | its first IP address, and the offset of its next |
  | 40 | its first gateway, and the offset of its next |
  | 40 | its DHCP server |
  | 4, 40, 40 | whether it has WINS, and its two WINS servers |
  | 8, 8 | when its DHCP lease was had and when it ends |

  Each address of 40 bytes is the offset of the next, 0 after the last; the address and the mask
  as 16 bytes of text each, with zeros after; and 4 bytes more. An adapter's further addresses come
  after it, before the next adapter. `0.0.0.0` stands for none: an adapter without an address,
  gateway or DHCP server lists that.

  The lease times aren't read: a system has answered bytes there that aren't times, for an adapter
  without DHCP; nor WINS, which TwinCAT systems don't use. The strings are in the system's code
  page, as Windows' ANSI functions give them, Windows-1252 unless told otherwise (see
  `ADS.Codepage`).
  """

  alias ADS.Codepage

  defstruct name: "",
            description: "",
            mac: "",
            index: 0,
            type: :ethernet,
            dhcp: false,
            addresses: [],
            gateways: [],
            dhcp_server: nil

  @typedoc """
  An adapter's type, as Windows' `MIB_IF_TYPE_*` and `IF_TYPE_IEEE80211` name them, or its number.
  """
  @type type ::
          :other
          | :ethernet
          | :token_ring
          | :fddi
          | :ppp
          | :loopback
          | :slip
          | :wireless
          | non_neg_integer

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          mac: String.t(),
          index: non_neg_integer,
          type: type,
          dhcp: boolean,
          addresses: [{:inet.ip4_address(), :inet.ip4_address()}],
          gateways: [:inet.ip4_address()],
          dhcp_server: :inet.ip4_address() | nil
        }

  @types %{
    1 => :other,
    6 => :ethernet,
    9 => :token_ring,
    15 => :fddi,
    23 => :ppp,
    24 => :loopback,
    28 => :slip,
    71 => :wireless
  }

  @adapter_size 648
  @address_size 40

  # Adapters, and addresses of each, so many and no more, of a list that links in circles.
  @max 64

  @doc """
  The adapters from the bytes of the list, or `:error` if they don't make one. No bytes are no
  adapters.

      iex> address = fn ip, mask -> <<0::32, ip::binary-16, mask::binary-16, 0::32>> end
      iex> text = fn string -> string <> :binary.copy(<<0>>, 16 - byte_size(string)) end
      iex> list =
      ...>   <<0::32, 9::32-little, "{5E97F165}", 0::size(250)-unit(8), "Intel Ethernet",
      ...>     0::size(118)-unit(8), 6::32-little, 0, 1, 5, 0x76, 0x34, 0xAE, 0, 0, 9::32-little,
      ...>     6::32-little, 0::32, 0::32>> <>
      ...>     address.(text.("10.0.0.5"), text.("255.255.255.0")) <>
      ...>     address.(text.("10.0.0.1"), text.("255.255.255.255")) <>
      ...>     address.(text.(""), text.("")) <> <<0::32>> <> address.(<<0::128>>, <<0::128>>) <>
      ...>     address.(<<0::128>>, <<0::128>>) <> <<0::128>>
      iex> ADS.Adapter.decode_all(list)
      {:ok, [%ADS.Adapter{name: "{5E97F165}", description: "Intel Ethernet",
                          mac: "00:01:05:76:34:AE", index: 9, type: :ethernet, dhcp: false,
                          addresses: [{{10, 0, 0, 5}, {255, 255, 255, 0}}],
                          gateways: [{10, 0, 0, 1}], dhcp_server: nil}]}
  """
  @spec decode_all(binary, Codepage.t()) :: {:ok, [t]} | :error
  def decode_all(bytes, codepage \\ Codepage.default())
  def decode_all(<<>>, _codepage), do: {:ok, []}
  def decode_all(bytes, codepage), do: adapters(bytes, 0, codepage, @max, [])

  defp adapters(_bytes, _at, _codepage, 0, _adapters), do: :error

  defp adapters(bytes, at, codepage, left, adapters) do
    with {:ok, next, adapter} <- adapter(bytes, at, codepage) do
      cond do
        next == 0 -> {:ok, Enum.reverse([adapter | adapters])}
        next > at -> adapters(bytes, next, codepage, left - 1, [adapter | adapters])
        true -> :error
      end
    end
  end

  defp adapter(bytes, at, codepage) when at + @adapter_size <= byte_size(bytes) do
    <<_::binary-size(at), next::32-little, _combo::32, name::binary-260, description::binary-132,
      mac_length::32-little, mac::binary-8, index::32-little, type::32-little, dhcp::32-little,
      _current::32, addresses::binary-40, gateways::binary-40, dhcp_server::binary-40, _::binary>> =
      bytes

    with true <- mac_length <= 8,
         {:ok, addresses} <- addresses(bytes, addresses, @max, []),
         {:ok, gateways} <- addresses(bytes, gateways, @max, []),
         {:ok, dhcp_server} <- dhcp_server(dhcp_server) do
      {:ok, next,
       %__MODULE__{
         name: string(name, codepage),
         description: string(description, codepage),
         mac: mac |> binary_part(0, mac_length) |> Base.encode16() |> colons(),
         index: index,
         type: Map.get(@types, type, type),
         dhcp: dhcp != 0,
         addresses: Enum.reject(addresses, &(elem(&1, 0) == {0, 0, 0, 0})),
         gateways: for({ip, _mask} <- gateways, ip != {0, 0, 0, 0}, do: ip),
         dhcp_server: dhcp_server
       }}
    else
      _ -> :error
    end
  end

  defp adapter(_bytes, _at, _codepage), do: :error

  # An address and those it links to, each further one at its offset in the list.
  defp addresses(_bytes, _address, 0, _addresses), do: :error

  defp addresses(bytes, <<next::32-little, ip::binary-16, mask::binary-16, _::32>>, left, found) do
    with {:ok, ip} <- ip(ip),
         {:ok, mask} <- ip(mask) do
      found = [{ip, mask} | found]

      cond do
        next == 0 -> {:ok, Enum.reverse(found)}
        address = at(bytes, next) -> addresses(bytes, address, left - 1, found)
        true -> :error
      end
    end
  end

  # The address at an offset in the list, or nil past its end.
  defp at(bytes, offset) do
    case bytes do
      <<_::binary-size(offset), address::binary-size(@address_size), _::binary>> -> address
      _ -> nil
    end
  end

  # The one address of a DHCP server, or nil for none.
  defp dhcp_server(<<_::32, ip::binary-16, _::binary>>) do
    case ip(ip) do
      {:ok, {0, 0, 0, 0}} -> {:ok, nil}
      other -> other
    end
  end

  # An address as text, with zeros after; none, as an empty one, is 0.0.0.0.
  defp ip(bytes) do
    case bytes |> :binary.split(<<0>>) |> hd() do
      "" ->
        {:ok, {0, 0, 0, 0}}

      text ->
        case :inet.parse_ipv4strict_address(:binary.bin_to_list(text)) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> :error
        end
    end
  end

  defp colons(hex), do: hex |> String.graphemes() |> Enum.chunk_every(2) |> Enum.join(":")

  defp string(bytes, codepage),
    do: bytes |> :binary.split(<<0>>) |> hd() |> Codepage.decode(codepage)
end
