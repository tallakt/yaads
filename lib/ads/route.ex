defmodule ADS.Route do
  @moduledoc """
  A route of a TwinCAT system, as its system service lists them, one entry at a time, for
  `ADS.Client.routes/2`: index group 803, `SYSTEMSERVICE_ENUMREMOTE` in Beckhoff's Tc2_Utilities,
  on AMS port 10000, the entry's index as the offset. After the last, the system answers
  `:device_no_more_handles`.

  Beckhoff documents the index group, and the fields of a route (`ST_AmsRouteEntry`), but not how
  an entry comes; this layout is as TwinCAT 3.1 4026 answers. All numbers are little-endian:

  | Bytes | Field |
  |---|---|
  | 6 | the route's AMS NetId |
  | 2 | its transport, 1 for TCP/IP |
  | 4 | its flags |
  | 4 | its timeout, in ms |
  | 16 | zeros |
  | 4, 4, 4 | the lengths of its address, its name, and a third string, each with a zero after |
  | ... | the address, the name, and the third, empty on every route seen |

  Of the flags, Beckhoff names `0x1`, temporary, `0x2`, dynamic, a host name rather than an
  address, and `0x4`, not to be overridden (see `flags/1`); TwinCAT sets others as well, such as
  `0x8` and `0x40`, which it doesn't name. The strings are in Windows-1252.
  """

  alias ADS.{NetId, Secure}

  defstruct name: "", net_id: "", address: "", transport: :tcp_ip, flags: 0, timeout: 0

  @type t :: %__MODULE__{
          name: String.t(),
          net_id: ADS.net_id(),
          address: String.t(),
          transport: atom | non_neg_integer,
          flags: non_neg_integer,
          timeout: non_neg_integer
        }

  # E_RouteTransportType, as Beckhoff's Tc2_Utilities names its values.
  @transports %{
    0 => :none,
    1 => :tcp_ip,
    2 => :iio_lightbus,
    3 => :profibus_dp,
    4 => :pci_isa_bus,
    5 => :ads_udp,
    6 => :fatp_udp,
    7 => :com_port,
    8 => :usb,
    9 => :can_open,
    10 => :device_net,
    12 => :soap
  }

  @doc """
  A route from the bytes of an entry, or `:error` if they don't make one.

      iex> entry =
      ...>   <<10, 0, 0, 7, 1, 1, 1::16-little, 0::32, 60_000::32-little, 0::128, 9::32-little,
      ...>     6::32-little, 0::32, "10.0.0.7", 0, "scada", 0>>
      iex> ADS.Route.decode(entry)
      {:ok, %ADS.Route{name: "scada", net_id: "10.0.0.7.1.1", address: "10.0.0.7",
                       transport: :tcp_ip, flags: 0, timeout: 60_000}}
  """
  @spec decode(binary) :: {:ok, t} | :error
  def decode(
        <<net_id::binary-6, transport::16-little, flags::32-little, timeout::32-little,
          _reserved::binary-16, address_length::32-little, name_length::32-little,
          third_length::32-little, rest::binary>>
      )
      when address_length + name_length + third_length <= byte_size(rest) do
    <<address::binary-size(address_length), name::binary-size(name_length), _::binary>> = rest

    {:ok,
     %__MODULE__{
       name: string(name),
       net_id: NetId.to_string(net_id),
       address: string(address),
       transport: Map.get(@transports, transport, transport),
       flags: flags,
       timeout: timeout
     }}
  end

  def decode(_bytes), do: :error

  # ROUTE_FLAG_TEMPORARY, ROUTE_FLAG_DYNAMIC and ROUTE_FLAG_NOOVERRIDE, in Beckhoff's Tc2_Utilities.
  @flags [temporary: 0x1, dynamic: 0x2, no_override: 0x4]

  @doc """
  The flags of a route that Beckhoff names, and `:unknown` with the bits it doesn't, if any.

      iex> ADS.Route.flags(%ADS.Route{flags: 0x41})
      [:temporary, {:unknown, 0x40}]
  """
  @spec flags(t) :: [:temporary | :dynamic | :no_override | {:unknown, pos_integer}]
  def flags(%__MODULE__{flags: flags}) do
    named = for {name, bit} <- @flags, Bitwise.band(flags, bit) != 0, do: name
    rest = Bitwise.band(flags, Bitwise.bnot(0x7))
    if rest == 0, do: named, else: named ++ [{:unknown, rest}]
  end

  defp string(bytes), do: bytes |> :binary.split(<<0>>) |> hd() |> Secure.ansi()
end
