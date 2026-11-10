defmodule Mix.Tasks.Ads.Symbols do
  @shortdoc "Lists a TwinCAT PLC's variables, and describes its types"

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

  `--type` describes a type instead, as the PLC does: the members of a structure or a function
  block, the values of an enumeration, or what another name or an array stands for. `--filter`
  keeps the members with a text in their names.

      $ mix ads.symbols 10.0.0.5 --type ST_Pump
      CX-1234AB (10.0.0.5), 5.36.69.176.1.1, AMS port 851

        ST_Pump, 32 bytes, 3 members

        Name      Type        Offset  Size  Comment
        bRunning  BOOL        0       1
        fSpeed    LREAL       8       8     [rpm]
        sTag      STRING(10)  16      11

  `--tsv` gives either tab-separated, under a header, with the index group, the offset and the
  flags of each variable as well, for a spreadsheet or another program; with the PLC's address
  given, nothing else comes out:

      $ mix ads.symbols 10.0.0.5 --tsv > symbols.tsv

  ## Options

    * `--filter TEXT` - only the names with TEXT in them, in any case; as often as needed, for the
      names with any of them
    * `--type NAME` - describe the type NAME, as often as needed, rather than list the variables
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

  alias ADS.{Client, DataType, Symbol}

  @requirements ["app.config"]

  @switches [
    filter: :keep,
    type: :keep,
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

  # A member that is a BIT: its offset and size count bits.
  @bit_values 0x0020

  @impl Mix.Task
  def run(argv) do
    {opts, hosts} = parse!(argv)
    {:ok, _} = Application.ensure_all_started(:yaads)

    device = device!(hosts, opts)
    client = connect!(device, opts)

    try do
      case for {:type, name} <- opts, do: name do
        [] -> variables!(client, device, opts)
        names -> types!(client, device, names, opts)
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
  defp timeout(opts), do: [timeout: opts[:timeout] || 10_000]

  # With no --filter, all of them; else those with any of the texts in their names.
  defp wanted?(name, opts) do
    case for {:filter, text} <- opts, do: String.downcase(text) do
      [] -> true
      texts -> String.contains?(String.downcase(name), texts)
    end
  end

  ## The variables

  defp variables!(client, device, opts) do
    symbols =
      case Client.symbols(client, timeout(opts)) do
        {:ok, symbols} ->
          Enum.sort_by(symbols, &String.downcase(&1.name))

        {:error, reason} when reason in [:closed, :timeout] ->
          no_route!(device, reason)

        {:error, reason} ->
          Mix.raise(
            "#{label(device)} gave no symbols on AMS port #{ams_port(opts)} " <>
              "(#{inspect(reason)}). Is a PLC runtime there, built with symbols?"
          )
      end

    shown = Enum.filter(symbols, &wanted?(&1.name, opts))

    if opts[:tsv] do
      Mix.shell().info(variables_tsv(shown))
    else
      Mix.shell().info(heading(device, opts))
      Mix.shell().info(variables_table(shown, length(symbols)))
    end
  end

  defp variables_table(shown, total) do
    rows = for s <- shown, do: [s.name, s.type, "#{s.size}", one_line(s.comment)]

    count =
      if length(shown) == total, do: count(total), else: "#{length(shown)} of #{count(total)}"

    lines =
      if shown == [], do: [], else: tl(columns([["Name", "Type", "Size", "Comment"] | rows]))

    [lines, "  #{count}\n"]
  end

  defp count(1), do: "1 variable"
  defp count(n), do: "#{n} variables"

  defp variables_tsv(shown) do
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

    tsv([~w(name type size index_group index_offset flags comment) | rows])
  end

  # The shell ends the last line itself.
  defp tsv(rows), do: Enum.map_join(rows, "\n", &Enum.join(&1, "\t"))

  ## The types

  defp types!(client, device, names, opts) do
    types =
      for name <- names do
        case Client.data_type(client, name, timeout(opts)) do
          {:ok, type} ->
            type

          {:error, reason} when reason in [:closed, :timeout] ->
            no_route!(device, reason)

          {:error, reason} ->
            Mix.raise(
              "#{label(device)} has no type #{name} on AMS port #{ams_port(opts)} " <>
                "(#{inspect(reason)})"
            )
        end
      end

    if opts[:tsv] do
      Mix.shell().info(Enum.map_join(types, "\n\n", &type_tsv(&1, opts)))
    else
      Mix.shell().info(heading(device, opts))
      Mix.shell().info(Enum.intersperse(Enum.map(types, &type_table(&1, opts)), "\n"))
    end
  end

  defp type_table(%DataType{} = t, opts) do
    comment = if t.comment == "", do: "", else: "  #{one_line(t.comment)}"
    title = "  #{t.name}, #{bytes(t.size)}, #{kind(t)}#{comment}\n"

    case rows(t, opts) do
      nil -> title
      {_header, []} -> [title, "\n  None of them has that in its name.\n"]
      {header, rows} -> [title, columns([header | rows])]
    end
  end

  defp type_tsv(%DataType{} = t, opts) do
    case rows(t, opts) do
      nil -> tsv([~w(name type size), [t.name, t.type, "#{t.size}"]])
      {header, rows} -> tsv([Enum.map(header, &String.downcase/1) | rows])
    end
  end

  # The members of a structure or a function block, or the values of an enumeration; nil for an
  # array or another name for a type, which its title says all of.
  defp rows(%DataType{members: [_ | _] = members}, opts) do
    rows =
      for m <- members, wanted?(m.name, opts) do
        [m.name, m.type, place(m), extent(m), one_line(m.comment)]
      end

    {["Name", "Type", "Offset", "Size", "Comment"], rows}
  end

  defp rows(%DataType{enum: [_ | _] = values}, opts),
    do:
      {["Name", "Value"],
       for({name, value} <- values, wanted?(name, opts), do: [name, "#{value}"])}

  defp rows(_type, _opts), do: nil

  defp kind(%DataType{members: [_]}), do: "1 member"
  defp kind(%DataType{members: [_ | _] = members}), do: "#{length(members)} members"
  defp kind(%DataType{enum: [_ | _]} = t), do: "an enumeration of #{t.type}"

  defp kind(%DataType{array: [_ | _] = dims} = t) do
    ranges = Enum.map_join(dims, ", ", fn {first, n} -> "#{first}..#{first + n - 1}" end)
    "an array [#{ranges}] of #{t.type}"
  end

  defp kind(%DataType{type: ""}), do: "with no members"
  defp kind(%DataType{type: type}), do: "another name for #{type}"

  defp bit?(member), do: Bitwise.band(member.flags, @bit_values) != 0

  defp place(member), do: if(bit?(member), do: "bit #{member.offset}", else: "#{member.offset}")

  defp extent(member) do
    cond do
      not bit?(member) -> "#{member.size}"
      member.size == 1 -> "1 bit"
      true -> "#{member.size} bits"
    end
  end

  defp bytes(1), do: "1 byte"
  defp bytes(n), do: "#{n} bytes"
end
