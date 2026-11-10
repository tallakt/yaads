defmodule Mix.Tasks.Ads.Symbols do
  @shortdoc "Lists a TwinCAT PLC's variables, with their types and comments"

  @moduledoc """
  Finds a PLC as `mix ads.route` does, uploads the table of its variables, the symbols its program
  was built with, and lists them by name, each with its type, its size in bytes and its comment. It
  answers only to a machine it has a route for, which `mix ads.route` adds.

      $ mix ads.symbols 10.0.0.5
      CX-1234AB (10.0.0.5), 5.36.69.176.1.1, AMS port 851

        Name         Type     Size  Comment
        MAIN.bRun    BOOL     1     Start the pump
        MAIN.fLevel  LREAL    8     [m] from the level transmitter
        MAIN.stPump  ST_Pump  24
        3 variables

  `--filter` keeps the names with a text in them, in any case, as often as given:

      $ mix ads.symbols 10.0.0.5 --filter pump
      ...
        1 of 3 variables

  `--tsv` gives them tab-separated, under a header, with the index group, the offset and the flags
  as well, for a spreadsheet or another program; with the PLC's address given, nothing else comes
  out:

      $ mix ads.symbols 10.0.0.5 --tsv > symbols.tsv

  ## Options

    * `--filter TEXT` - only the names with TEXT in them, in any case; as often as needed, for the
      names with any of them
    * `--tsv` - tab-separated, with the index group, the offset and the flags
    * `--ams-port` - the PLC runtime, if not 851: 852 for the second of TwinCAT 3, 801 for TwinCAT 2
    * `--net-id` - this machine's NetId, as the PLC's route has it, if not its address with `.1.1`
    * `--search` - where to search, a broadcast address or a PLC's, as often as needed (default
      every network this machine is on)
    * `--yes`, `-y` - take the only PLC that answers without asking
    * `--codepage` - of the PLC's strings, such as `windows-1251`, if not Windows-1252 (see
      `ADS.Codepage`)
    * `--timeout` - how long to wait for answers, in ms (default 2000 for the search, and 10000
      for the upload)
    * `--tcp-port`, `--udp-port` - if not 48898 and 48899
  """

  use Mix.Task

  import Mix.ADS

  alias ADS.{Client, NetId, Symbol}

  @requirements ["app.config"]

  @switches [
    filter: :keep,
    tsv: :boolean,
    ams_port: :integer,
    net_id: :string,
    search: :keep,
    yes: :boolean,
    codepage: :string,
    timeout: :integer,
    tcp_port: :integer,
    udp_port: :integer
  ]

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
      symbols = symbols!(client, device, opts)
      shown = Enum.filter(symbols, &wanted?(&1, opts))

      if opts[:tsv] do
        Mix.shell().info(tsv(shown))
      else
        Mix.shell().info("#{label(device)}, #{device.net_id}, AMS port #{ams_port(opts)}\n")
        Mix.shell().info(table(shown, length(symbols)))
      end
    after
      Client.stop(client)
    end
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: [y: :yes]) do
      {opts, hosts, []} when length(hosts) <= 1 -> {opts, hosts}
      {_, _, [{option, _} | _]} -> Mix.raise("Unknown option #{option}; see mix help ads.symbols")
      _ -> Mix.raise("Expected at most one PLC; see mix help ads.symbols")
    end
  end

  defp ams_port(opts), do: opts[:ams_port] || 851

  defp symbols!(client, device, opts) do
    case Client.symbols(client, timeout: opts[:timeout] || 10_000) do
      {:ok, symbols} ->
        Enum.sort_by(symbols, &String.downcase(&1.name))

      {:error, reason} when reason in [:closed, :timeout] ->
        Mix.raise(
          "No answer from #{label(device)} over ADS (#{inspect(reason)}). It answers only a " <>
            "machine it has a route for: mix ads.route adds one."
        )

      {:error, reason} ->
        Mix.raise(
          "#{label(device)} gave no symbols on AMS port #{ams_port(opts)} (#{inspect(reason)}). " <>
            "Is a PLC runtime there, built with symbols?"
        )
    end
  end

  # With no --filter, all of them; else those with any of the texts in their names.
  defp wanted?(symbol, opts) do
    case for {:filter, text} <- opts, do: String.downcase(text) do
      [] -> true
      texts -> String.contains?(String.downcase(symbol.name), texts)
    end
  end

  defp table(shown, total) do
    rows = for s <- shown, do: [s.name, s.type, "#{s.size}", one_line(s.comment)]

    count =
      if length(shown) == total, do: count(total), else: "#{length(shown)} of #{count(total)}"

    lines =
      if shown == [], do: [], else: tl(columns([["Name", "Type", "Size", "Comment"] | rows]))

    [lines, "  #{count}\n"]
  end

  defp count(1), do: "1 variable"
  defp count(n), do: "#{n} variables"

  defp tsv(shown) do
    header = ~w(name type size index_group index_offset flags comment)

    rows =
      for s <- shown do
        [
          s.name,
          s.type,
          "#{s.size}",
          "0x" <> Integer.to_string(s.index_group, 16),
          "#{s.index_offset}",
          Enum.map_join(Symbol.flags(s), ",", &Atom.to_string/1),
          one_line(s.comment)
        ]
      end

    # The shell ends the last line itself.
    Enum.map_join([header | rows], "\n", &Enum.join(&1, "\t"))
  end

  # A comment over several lines, or with tabs, as one line.
  defp one_line(comment), do: comment |> String.replace(~r/\s+/, " ") |> String.trim()
end
