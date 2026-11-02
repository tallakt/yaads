defmodule Mix.Tasks.Ads.Info do
  @shortdoc "Shows a TwinCAT system's state, host name and network adapters"

  @moduledoc """
  Finds the PLCs on the network, as `mix ads.route` does, and shows what one's system service
  answers: its version and state, its host name and its network adapters. It answers only to a
  machine it has a route for, which `mix ads.route` adds.

      $ mix ads.info 10.0.0.5
      CX-1234AB (10.0.0.5), 5.36.69.176.1.1

        TwinCAT System 3.1.4026, in run
        Host name  CX-1234AB

        Adapter                                       MAC                DHCP  Addresses
        TwinCAT-Intel PCI Ethernet Adapter (Gigabit)  00:01:05:76:34:AE  no    10.0.0.5/24
                                                                               gateway 10.0.0.1

  `--resolve` looks a host name up on the PLC, with its DNS and hosts file, as often as given:

      $ mix ads.info 10.0.0.5 --resolve scada-1 --resolve nowhere.invalid
        scada-1          10.0.0.7
        nowhere.invalid  not found

  ## Options

    * `--state`, `--host-name`, `--adapters` - show only these; all three if none is given, nor
      `--resolve`
    * `--resolve NAME` - the address the PLC finds for a host name
    * `--net-id` - this machine's NetId, as the PLC's route has it, if not its address with `.1.1`
    * `--search` - where to search, a broadcast address or a PLC's, as often as needed (default
      every network this machine is on)
    * `--yes`, `-y` - take the only PLC that answers without asking
    * `--codepage` - of the PLC's strings, such as `windows-1251`, if not Windows-1252 (see
      `ADS.Codepage`)
    * `--timeout` - how long to wait for answers over UDP, in ms (default 2000 for the search,
      5000 otherwise)
    * `--tcp-port`, `--udp-port` - if not 48898 and 48899
  """

  use Mix.Task

  import Mix.ADS

  alias ADS.{Adapter, Client, NetId}

  @requirements ["app.config"]

  @switches [
    state: :boolean,
    host_name: :boolean,
    adapters: :boolean,
    resolve: :keep,
    net_id: :string,
    search: :keep,
    yes: :boolean,
    codepage: :string,
    timeout: :integer,
    tcp_port: :integer,
    udp_port: :integer
  ]

  @system_service 10_000

  @impl Mix.Task
  def run(argv) do
    {opts, hosts} = parse!(argv)
    {:ok, _} = Application.ensure_all_started(:yaads)

    device = device!(hosts, opts)
    local_net_id = device.address |> local_address!(opts) |> NetId.from_ip() |> NetId.to_string()
    net_id = opts[:net_id] && ask(opts, :net_id, "This machine's NetId", nil, &net_id/1)

    {:ok, client} =
      Client.start_link(client(device, if(net_id != local_net_id, do: net_id), opts))

    try do
      Mix.shell().info("#{label(device)}, #{device.net_id}\n")
      show!(client, device, shown(opts))
    after
      Client.stop(client)
    end
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: [y: :yes]) do
      {opts, hosts, []} when length(hosts) <= 1 -> {opts, hosts}
      {_, _, [{option, _} | _]} -> Mix.raise("Unknown option #{option}; see mix help ads.info")
      _ -> Mix.raise("Expected at most one PLC; see mix help ads.info")
    end
  end

  # What's asked for, in order: all of state, host name and adapters if none is, nor a name.
  defp shown(opts) do
    names = for {:resolve, name} <- opts, do: {:resolve, name}
    picked = for key <- [:state, :host_name, :adapters], opts[key], do: key
    if picked == [] and names == [], do: [:state, :host_name, :adapters], else: picked ++ names
  end

  defp show!(client, device, shown) do
    # The first answer tells whether there's a route; the rest go as they come.
    _ = answer!(client, device)

    {names, rest} = Enum.split_with(shown, &match?({:resolve, _}, &1))

    lines =
      Enum.map(rest, fn
        :state -> state(client)
        :host_name -> host_name(client)
        :adapters -> adapters(client)
      end)

    lines = if names == [], do: lines, else: lines ++ [resolved(client, names)]
    Mix.shell().info(Enum.intersperse(lines, "\n"))
  end

  defp answer!(client, device) do
    case Client.read_state(client, port: @system_service) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Mix.raise(
          "No answer from #{label(device)} over ADS (#{inspect(reason)}). It answers only a " <>
            "machine it has a route for: mix ads.route adds one."
        )
    end
  end

  defp state(client) do
    with {:ok, %{name: name, version: {major, minor, build}}} <-
           Client.read_device_info(client, port: @system_service),
         {:ok, %{ads_state: state}} <- Client.read_state(client, port: @system_service) do
      "  #{name} #{major}.#{minor}.#{build}, in #{state}\n"
    else
      {:error, reason} -> "  State: #{inspect(reason)}\n"
    end
  end

  defp host_name(client) do
    case Client.host_name(client) do
      {:ok, name} -> "  Host name  #{name}\n"
      {:error, reason} -> "  Host name: #{inspect(reason)}\n"
    end
  end

  defp adapters(client) do
    case Client.adapters(client) do
      {:ok, []} -> "  No network adapters.\n"
      {:ok, adapters} -> adapters_table(adapters)
      {:error, reason} -> "  Adapters: #{inspect(reason)}\n"
    end
  end

  # A row for each adapter, and one more for each address and gateway past its first.
  defp adapters_table(adapters) do
    rows =
      Enum.flat_map(adapters, fn %Adapter{} = a ->
        [first | more] = addresses(a)

        [
          [a.description, a.mac, if(a.dhcp, do: "yes", else: "no"), first]
          | for(m <- more, do: ["", "", "", m])
        ]
      end)

    columns([["Adapter", "MAC", "DHCP", "Addresses"] | rows]) |> tl()
  end

  defp addresses(adapter) do
    own = for {address, mask} <- adapter.addresses, do: "#{ip(address)}/#{prefix(mask)}"
    gateways = for gateway <- adapter.gateways, do: "gateway #{ip(gateway)}"
    dhcp = if server = adapter.dhcp_server, do: ["DHCP server #{ip(server)}"], else: []

    case own ++ gateways ++ dhcp do
      [] -> ["-"]
      lines -> lines
    end
  end

  # A mask's length, as 24 for 255.255.255.0.
  defp prefix({a, b, c, d}) do
    for(<<(bit::1 <- <<a, b, c, d>>)>>, bit == 1, do: bit) |> length()
  end

  defp resolved(client, names) do
    rows =
      for {:resolve, name} <- names do
        case Client.host_address(client, name) do
          {:ok, address} -> [name, ip(address)]
          {:error, :device_not_found} -> [name, "not found"]
          {:error, reason} -> [name, inspect(reason)]
        end
      end

    rows |> columns() |> tl()
  end
end
