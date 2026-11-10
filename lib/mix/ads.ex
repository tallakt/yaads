defmodule Mix.ADS do
  @moduledoc false
  # What the mix tasks have in common: finding the PLC, asking, and showing.

  alias ADS.{Discovery, NetId}

  # The PLC given, or one of those that answer a search.
  def device!([host], opts) do
    case Discovery.info(host, udp(opts)) do
      {:ok, device} ->
        device

      {:error, reason} ->
        Mix.raise(
          "No answer from #{host} on UDP port #{opts[:udp_port] || 48899} (#{inspect(reason)}). " <>
            "Is it a TwinCAT system, and does no firewall stop the port?"
        )
    end
  end

  def device!([], opts) do
    Mix.shell().info("Searching for PLCs...")
    search = for {:search, to} <- opts, do: to
    search = if search == [], do: [], else: [to: search]

    devices =
      case Discovery.search(search ++ udp(opts)) do
        {:ok, devices} -> Enum.sort_by(devices, & &1.address)
        {:error, reason} -> Mix.raise("Couldn't search: #{inspect(reason)}")
      end

    choose(devices, opts)
  end

  # A firewall that lets in only answers to what was sent drops those to a broadcast, as they come
  # from another address than it went to.
  @no_answer """
  No PLCs answered. A firewall on this machine may have dropped their answers to the broadcast, as
  ufw does: give a PLC's address, or let them in, as with
  `sudo ufw allow proto udp from any port 48899`.\
  """

  def choose([], opts) do
    if opts[:yes], do: Mix.raise(@no_answer)
    Mix.shell().info(@no_answer)
    device!([ask(opts, :host, "PLC's address", nil)], opts)
  end

  def choose(devices, opts) do
    Mix.shell().info(table(devices))
    n = length(devices)
    if opts[:yes] && n > 1, do: Mix.raise("#{n} PLCs answered; give one, by its address")

    choice = fn answer ->
      case Integer.parse(answer) do
        {i, ""} when i in 1..n//1 -> {:ok, Enum.at(devices, i - 1)}
        {_, ""} -> {:error, "Not one of 1-#{n}: #{answer}"}
        _ -> {:ok, answer}
      end
    end

    case ask(opts, :host, "PLC (1-#{n}, or an address)", if(n == 1, do: "1"), choice) do
      %{} = device -> device
      host -> device!([host], opts)
    end
  end

  # A line for each device, numbered, in columns.
  def table(devices) do
    devices
    |> Enum.with_index(1)
    |> Enum.map(fn {d, i} -> ["#{i}", d.name || "-", ip(d.address), d.net_id] end)
    |> columns()
  end

  def columns(rows) do
    widths = rows |> Enum.zip() |> Enum.map(fn column -> column |> Tuple.to_list() |> width() end)

    lines =
      for row <- rows do
        row
        |> Enum.zip(widths)
        |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(cell, w) end)
        |> String.trim_trailing()
      end

    ["\n", Enum.map(lines, &["  ", &1, "\n"])]
  end

  def width(cells), do: cells |> Enum.map(&String.length/1) |> Enum.max()

  # This machine's address towards the device, for its NetId by default, as the client has it.
  def local_address!(ip, opts) do
    {:ok, socket} = :gen_udp.open(0, [:binary])

    try do
      with :ok <- :gen_udp.connect(socket, ip, opts[:udp_port] || 48899),
           {:ok, {local, _port}} <- :inet.sockname(socket) do
        local
      else
        {:error, reason} -> Mix.raise("No way to #{ip(ip)}: #{inspect(reason)}")
      end
    after
      :gen_udp.close(socket)
    end
  end

  # The client's options, as start_link/1 is to have them.
  def client(device, net_id, opts) do
    [
      host: ip(device.address),
      net_id: device.net_id,
      local_net_id: net_id,
      port: opts[:tcp_port],
      ams_port: opts[:ams_port],
      codepage: codepage!(opts)
    ]
    |> Enum.reject(fn {_key, value} -> value == nil end)
  end

  # An answer, or what's in brackets: asked, unless given as an option or --yes says to take it,
  # and asked again until there's one that check gives {:ok, value} for.
  def ask(opts, key, question, default, check \\ &{:ok, &1}) do
    given = Keyword.get(opts, key) || if(opts[:yes], do: default)
    prompt = if default, do: "#{question} [#{default}]:", else: "#{question}:"

    case check.(given || answer(Mix.shell().prompt(prompt), default)) do
      {:ok, ""} ->
        ask(opts, key, question, default, check)

      {:ok, value} ->
        value

      {:error, message} when given != nil ->
        Mix.raise(message)

      {:error, message} ->
        Mix.shell().error(message)
        ask(opts, key, question, default, check)
    end
  end

  def answer(:eof, _default) do
    Mix.raise(
      "No more input. Run it in a terminal to be asked, or give the PLC and the options, and " <>
        "--yes, for nothing to be asked"
    )
  end

  def answer(line, default) do
    case String.trim(line) do
      "" -> default || ""
      answer -> answer
    end
  end

  def net_id(answer) do
    case NetId.parse(answer) do
      {:ok, _} -> {:ok, answer}
      :error -> {:error, "Not a NetId, such as 10.0.0.7.1.1: #{answer}"}
    end
  end

  def udp(opts) do
    udp =
      for {from, to} <- [udp_port: :port, timeout: :timeout], value = opts[from], do: {to, value}

    if codepage = codepage!(opts), do: [{:codepage, codepage} | udp], else: udp
  end

  # The code page given with --codepage, as windows-1251 or windows_1251 for :windows_1251, or a
  # name of Codepagex's; nil for the default.
  def codepage!(opts) do
    case opts[:codepage] do
      nil ->
        nil

      given ->
        codepage =
          if given =~ ~r/^[a-z][a-z0-9_-]*$/i,
            do: given |> String.downcase() |> String.replace("-", "_") |> String.to_atom(),
            else: given

        try do
          ADS.Codepage.check!(codepage)
        rescue
          e in ArgumentError -> Mix.raise(Exception.message(e))
        end
    end
  end

  # The device and the client's options as a task has them, and the line that says which it is.
  def connect!(device, opts) do
    local_net_id = device.address |> local_address!(opts) |> NetId.from_ip() |> NetId.to_string()
    net_id = opts[:net_id] && ask(opts, :net_id, "This machine's NetId", nil, &net_id/1)

    {:ok, client} =
      ADS.Client.start_link(client(device, if(net_id != local_net_id, do: net_id), opts))

    client
  end

  def heading(device, opts),
    do: "#{label(device)}, #{device.net_id}, AMS port #{opts[:ams_port] || 851}\n"

  # A device that doesn't answer over ADS, which it does only to a machine it has a route for.
  def no_route!(device, reason) do
    Mix.raise(
      "No answer from #{label(device)} over ADS (#{inspect(reason)}). It answers only a " <>
        "machine it has a route for: mix ads.route adds one."
    )
  end

  # A comment over several lines, or with tabs, as one line.
  def one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  def label(%{name: nil} = device), do: ip(device.address)
  def label(device), do: "#{device.name} (#{ip(device.address)})"

  def ip(address), do: address |> :inet.ntoa() |> List.to_string()
end
