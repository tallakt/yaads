defmodule Mix.Tasks.Ads.Read do
  @shortdoc "Reads variables of a TwinCAT PLC, and shows their values"

  @moduledoc """
  Reads variables of a PLC by name, through this machine's route, and shows each with its type and
  its value: a structure or a function block member by member, in the PLC's order, and an array
  element by element. It only reads. The PLC answers only to a machine it has a route for, which
  `mix ads.route` adds.

      $ mix ads.read 10.0.0.5 MAIN.fLevel MAIN.stPump
      CX-1234AB (10.0.0.5), 5.36.69.176.1.1, AMS port 851

        MAIN.fLevel  LREAL    1.25
        MAIN.stPump  ST_Pump
          bRunning  true
          fSpeed    1450.0
          sTag      "P-101"

  A name is as the PLC's program writes it: `MAIN.aValues[2]`, `GVL.stPump.fSpeed`, and `^` after
  a pointer for what it points to, as `GVL.apPumps[0]^.fSpeed`. A pointer's own value is an
  address, which is shown with a reminder of that.

  ## Options

    * `--ams-port` - the PLC runtime, if not 851: 852 for the second of TwinCAT 3, 801 for TwinCAT 2
    * `--net-id` - this machine's NetId, as the PLC's route has it, if not its address with `.1.1`
    * `--codepage` - of the PLC's strings, such as `windows-1251`, if not Windows-1252 (see
      `ADS.Codepage`)
    * `--timeout` - how long to wait for answers, in ms (default 2000 over UDP, and 5000 for a
      read)
    * `--tcp-port`, `--udp-port` - if not 48898 and 48899
  """

  use Mix.Task

  import Mix.ADS

  alias ADS.{Client, Type}

  @requirements ["app.config"]

  @switches [
    ams_port: :integer,
    net_id: :string,
    codepage: :string,
    timeout: :integer,
    tcp_port: :integer,
    udp_port: :integer
  ]

  # An array of no more elements than this, each a value of one line, is shown on one line.
  @inline 10

  @impl Mix.Task
  def run(argv) do
    {opts, host, names} = parse!(argv)
    {:ok, _} = Application.ensure_all_started(:yaads)

    device = device!([host], opts)
    client = connect!(device, opts)

    try do
      read = for name <- names, do: {name, read(client, device, name, opts)}
      Mix.shell().info(heading(device, opts))
      Mix.shell().info(shown(read))
    after
      Client.stop(client)
    end
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [host, name | names], []} -> {opts, host, [name | names]}
      {_, _, [{option, _} | _]} -> Mix.raise("Unknown option #{option}; see mix help ads.read")
      _ -> Mix.raise("Expected a PLC and the variables to read; see mix help ads.read")
    end
  end

  # The variable's type name, its type, and its value; or why not.
  defp read(client, device, name, opts) do
    request = if opts[:timeout], do: [timeout: opts[:timeout]], else: []

    with {:ok, symbol} <- Client.symbol(client, name, request),
         {:ok, value} <- Client.read(client, name, request) do
      {:ok, symbol.type, type(client, symbol, request), value}
    else
      {:error, :closed} -> no_route!(device, :closed)
      {:error, reason} -> {:error, reason}
    end
  end

  # As the PLC names it, sized as the variable is; or as the PLC describes it. nil if neither.
  defp type(client, symbol, request) do
    with :error <- Type.parse(symbol.type, symbol.size),
         {:error, _reason} <- Client.type(client, symbol.type, request) do
      nil
    else
      {:ok, type} -> type
    end
  end

  defp shown(read) do
    name_width = read |> Enum.map(fn {name, _} -> String.length(name) end) |> Enum.max()

    type_width =
      read
      |> Enum.map(fn
        {_name, {:ok, type_name, _type, _value}} -> String.length(type_name)
        {_name, {:error, _reason}} -> 0
      end)
      |> Enum.max()

    Enum.map(read, fn
      {name, {:ok, type_name, type, value}} ->
        head =
          "  #{String.pad_trailing(name, name_width)}  #{String.pad_trailing(type_name, type_width)}"

        body =
          case value(type, value) do
            {:parts, parts} -> [String.trim_trailing(head), "\n", lines(parts, "    ")]
            text -> [head, "  ", text, "\n"]
          end

        [body, pointer(name, type_name)]

      {name, {:error, reason}} ->
        "  #{String.pad_trailing(name, name_width)}  not read: #{inspect(reason)}\n"
    end)
  end

  # A line for each part, its label and its value, or its own parts under it.
  defp lines(parts, indent) do
    width =
      parts |> Enum.map(fn {label, _, _} -> String.length(label) end) |> Enum.max(fn -> 0 end)

    Enum.map(parts, fn {label, type, value} ->
      case value(type, value) do
        {:parts, parts} -> ["#{indent}#{label}\n", lines(parts, indent <> "  ")]
        text -> "#{indent}#{String.pad_trailing(label, width)}  #{text}\n"
      end
    end)
  end

  # A value as a line of text, or {:parts, [{label, type, value}]} for a line of each of them.
  defp value({kind, _size, members}, value) when kind in [:struct, :union] and is_map(value),
    do: {:parts, for({name, _offset, type} <- members, do: {name, type, Map.get(value, name)})}

  defp value({:array, element, [{first, _last} | more]}, values) when is_list(values) do
    element = if more == [], do: element, else: {:array, element, more}
    texts = for v <- values, do: value(element, v)

    if length(values) <= @inline and Enum.all?(texts, &is_binary/1),
      do: "[" <> Enum.join(texts, ", ") <> "]",
      else: {:parts, runs(values, first, element)}
  end

  defp value({:enum, _base, _values}, name) when is_binary(name), do: name
  defp value({:raw, _size}, bytes) when is_binary(bytes), do: "16#" <> Base.encode16(bytes)

  defp value(_type, %module{} = value) when module in [DateTime, NaiveDateTime, Date, Time],
    do: to_string(value)

  defp value(_type, value), do: inspect(value, limit: :infinity)

  # The elements of an array, those that are the same next to each other once, as [3..50].
  defp runs(values, first, element) do
    values
    |> Enum.with_index(first)
    |> Enum.chunk_by(fn {value, _index} -> value end)
    |> Enum.map(fn
      [{value, index}] -> {"[#{index}]", element, value}
      [{value, from} | rest] -> {"[#{from}..#{elem(List.last(rest), 1)}]", element, value}
    end)
  end

  # A pointer's value is where its target is, not the target.
  defp pointer(name, type_name) do
    cond do
      type_name =~ ~r/^POINTER TO /i ->
        "    an address: #{name}^ is what it points to\n"

      type_name =~ ~r/^ARRAY\s*\[.*\]\s*OF\s+POINTER TO /i ->
        "    addresses: #{name}[i]^ is what one points to\n"

      true ->
        []
    end
  end
end
