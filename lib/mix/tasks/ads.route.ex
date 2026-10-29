defmodule Mix.Tasks.Ads.Route do
  @shortdoc "Adds a route on a TwinCAT PLC for this machine"

  @moduledoc """
  Finds the PLCs on the network, and adds a route on one for this machine with the login of a user
  on it, so that `ADS.Client` can connect; then connects, to see that it can:

      $ mix ads.route
      Searching for PLCs...

        1  CX-1234AB   10.0.0.5   5.36.69.176.1.1
        2  DESKTOP-B9  10.0.0.9   10.0.0.9.1.1

      PLC (1-2, or an address): 1
      User [Administrator]:
      Password:
      This machine's NetId [10.0.0.7.1.1]:
      Route name [scada-1]:
      Adding a route on CX-1234AB (10.0.0.5)...
      Connecting...
      Connected to Plc30 App 3.1.4026, in run.

          {:ok, plc} = ADS.Client.start_link(host: "10.0.0.5", net_id: "5.36.69.176.1.1")

  A firewall on this machine, such as ufw, may drop the PLCs' answers to the search, as they come
  from another address than the broadcast went to; a PLC asked by its address answers through it.

  Enter takes what's in brackets. A PLC given on the command line isn't searched for, and an
  option given isn't asked for; `--yes` takes what's in brackets without asking:

      $ mix ads.route 10.0.0.5 --yes

  As with TwinCAT's own tools, the password goes over the network unencrypted. The search and the
  route go over UDP port 48899 (see `ADS.Discovery`), and the connection over TCP port 48898.

  ## Options

    * `--user`, `--password`, `--net-id`, `--name` - as asked; a password given here is kept in
      the shell's history
    * `--address` - this machine's address as the PLC is to know it, as behind NAT (default the
      address it sends from)
    * `--search` - where to search, a broadcast address or a PLC's, as often as needed (default
      every network this machine is on)
    * `--yes`, `-y` - take what's in brackets without asking
    * `--no-connect` - don't connect after
    * `--list` - list the PLC's routes rather than add one, through this machine's route to it,
      which it needs; no login is asked for
    * `--delete` - delete the route rather than add it, asked for as when adding it, and with no
      connecting after; the route of the name, which TwinCAT deletes by, as it was added. If this
      machine has a route there, the name is looked for among the PLC's routes first, and nothing
      is sent if it isn't one of them; and after, as TwinCAT's answer doesn't tell
    * `--timeout` - how long to wait for answers over UDP, in ms (default 2000 for the search,
      5000 otherwise)
    * `--tcp-port`, `--udp-port`, `--ams-port` - if not 48898, 48899 and 851
  """

  use Mix.Task

  alias ADS.{Client, Discovery, NetId, Route}

  @requirements ["app.config"]

  @switches [
    user: :string,
    password: :string,
    net_id: :string,
    name: :string,
    address: :string,
    search: :keep,
    yes: :boolean,
    connect: :boolean,
    delete: :boolean,
    list: :boolean,
    timeout: :integer,
    tcp_port: :integer,
    udp_port: :integer,
    ams_port: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, hosts} = parse!(argv)
    {:ok, _} = Application.ensure_all_started(:yaads)

    device = device!(hosts, opts)
    local = local_address!(device.address, opts)
    local_net_id = local |> NetId.from_ip() |> NetId.to_string()

    if opts[:list],
      do: list!(device, local_net_id, opts),
      else: change!(device, local_net_id, opts)
  end

  # The route added or deleted, as asked for.
  defp change!(device, local_net_id, opts) do
    user = ask(opts, :user, "User", "Administrator")
    password = opts[:password] || password()
    net_id = ask(opts, :net_id, "This machine's NetId", local_net_id, &net_id/1)
    name = ask(opts, :name, "Route name", host_name())

    route =
      [user: user, password: password, net_id: net_id, name: name] ++
        Keyword.take(opts, [:address]) ++ udp(opts)

    if opts[:delete] do
      client = client(device, if(net_id != local_net_id, do: net_id), opts)
      delete!(device, name, route, client)
    else
      Mix.shell().info("Adding a route on #{label(device)}...")
      route!(&Discovery.add_route/2, device, route)
      client = client(device, if(net_id != local_net_id, do: net_id), opts)
      if Keyword.get(opts, :connect, true), do: connect!(client)

      Mix.shell().info("""

          {:ok, plc} = ADS.Client.start_link(#{Enum.map_join(client, ", ", &option/1)})
      """)
    end
  end

  # The device's routes, through this machine's route to it.
  defp list!(device, local_net_id, opts) do
    net_id = opts[:net_id] && ask(opts, :net_id, "This machine's NetId", nil, &net_id/1)

    {:ok, client} =
      Client.start_link(client(device, if(net_id != local_net_id, do: net_id), opts))

    try do
      case Client.routes(client) do
        {:ok, routes} ->
          Mix.shell().info(routes_table(device, routes))

        {:error, reason} ->
          Mix.raise(
            "Couldn't list the routes of #{label(device)} (#{inspect(reason)}). " <>
              "It lists them only to a client it has a route for."
          )
      end
    after
      Client.stop(client)
    end
  end

  defp routes_table(device, []), do: "#{label(device)} has no routes."

  defp routes_table(_device, routes) do
    rows = for r <- routes, do: [r.name, r.net_id, r.address, flags(r)]
    columns([["Name", "NetId", "Address", "Flags"] | rows])
  end

  # As 0x41 (temporary, ?): those Beckhoff names, and ? for the rest.
  defp flags(%{flags: 0}), do: ""

  defp flags(route) do
    names =
      Enum.map_join(Route.flags(route), ", ", fn
        {:unknown, _bits} -> "?"
        name -> name |> Atom.to_string() |> String.replace("_", " ")
      end)

    "0x#{Integer.to_string(route.flags, 16)} (#{names})"
  end

  defp parse!(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: [y: :yes]) do
      {opts, hosts, []} when length(hosts) <= 1 -> {opts, hosts}
      {_, _, [{option, _} | _]} -> Mix.raise("Unknown option #{option}; see mix help ads.route")
      _ -> Mix.raise("Expected at most one PLC; see mix help ads.route")
    end
  end

  # The PLC given, or one of those that answer a search.
  defp device!([host], opts) do
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

  defp device!([], opts) do
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

  defp choose([], opts) do
    if opts[:yes], do: Mix.raise(@no_answer)
    Mix.shell().info(@no_answer)
    device!([ask(opts, :host, "PLC's address", nil)], opts)
  end

  defp choose(devices, opts) do
    Mix.shell().info(table(devices))
    n = length(devices)
    if opts[:yes] && n > 1, do: Mix.raise("#{n} PLCs answered; give one: mix ads.route ADDRESS")

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
  defp table(devices) do
    devices
    |> Enum.with_index(1)
    |> Enum.map(fn {d, i} -> ["#{i}", d.name || "-", ip(d.address), d.net_id] end)
    |> columns()
  end

  defp columns(rows) do
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

  defp width(cells), do: cells |> Enum.map(&String.length/1) |> Enum.max()

  # This machine's address towards the device, for its NetId by default, as the client has it.
  defp local_address!(ip, opts) do
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

  # The route added or deleted, or why not.
  defp route!(fun, device, route) do
    with {:error, _} = error <- route(fun, device, route), do: fail!(device, error)
  end

  defp route(fun, device, route) do
    fun.(device.address, route)
  rescue
    e in ArgumentError -> Mix.raise(Exception.message(e))
  end

  @spec fail!(map, {:error, term}) :: no_return
  defp fail!(device, error), do: fail!(device, error, nil)

  @spec fail!(map, {:error, term}, String.t() | nil) :: no_return

  defp fail!(device, {:error, :timeout}, _why),
    do: Mix.raise("No answer from #{label(device)} to the route.")

  defp fail!(device, {:error, reason}, nil), do: Mix.raise(refused(device, reason))
  defp fail!(device, {:error, reason}, why), do: Mix.raise(refused(device, reason) <> " " <> why)

  # The route deleted, looked for first among the device's routes, if this machine can see them:
  # TwinCAT 3.1 4026 answers :device_error for a route it hasn't, so that answer for a route that
  # was there is looked into again.
  defp delete!(device, name, route, client) do
    before = routes(client)

    _ =
      with {:ok, routes} <- before,
           false <- Enum.any?(routes, &(&1.name == name)),
           do: Mix.raise("#{label(device)} has no route named #{name}; nothing deleted.")

    Mix.shell().info("Deleting the route #{name} on #{label(device)}...")

    case {route(&Discovery.delete_route/2, device, route), before} do
      {answer, {:ok, _}} when answer in [:ok, {:error, :device_error}] ->
        gone!(device, name, client, answer)

      {:ok, _unseen} ->
        Mix.shell().info(
          "#{label(device)} answered :ok, but this machine has no route there to see its routes " <>
            "with, so whether there was one named #{name} to delete isn't known."
        )

      {{:error, :device_error} = error, _unseen} ->
        fail!(device, error, "TwinCAT answers so for a route it hasn't too.")

      {error, _} ->
        fail!(device, error)
    end
  end

  # A route that was there before: gone after, as the routes say, or the device by closing on
  # this machine, which it let in before. TwinCAT's answer alone doesn't tell.
  defp gone!(device, name, client, answer) do
    gone =
      case routes(client) do
        {:ok, routes} -> not Enum.any?(routes, &(&1.name == name))
        {:error, :closed} -> true
        {:error, _reason} -> false
      end

    cond do
      not gone ->
        fail!(device, {:error, :not_deleted}, "It answered #{inspect(answer)}, and has it still.")

      answer == :ok ->
        Mix.shell().info("Deleted.")

      true ->
        Mix.shell().info("Deleted, though #{label(device)} answered :device_error.")
    end
  end

  # The device's routes, as this machine sees them, or why not.
  defp routes(options) do
    {:ok, client} = Client.start_link(options)

    try do
      Client.routes(client)
    after
      Client.stop(client)
    end
  end

  # The client's options, as start_link/1 is to have them.
  defp client(device, net_id, opts) do
    [
      host: ip(device.address),
      net_id: device.net_id,
      local_net_id: net_id,
      port: opts[:tcp_port],
      ams_port: opts[:ams_port]
    ]
    |> Enum.reject(fn {_key, value} -> value == nil end)
  end

  defp refused(device, :device_invalid_access = reason),
    do: "#{label(device)} refused: #{inspect(reason)}. Are the user and password right?"

  defp refused(device, reason), do: "#{label(device)} refused: #{inspect(reason)}."

  defp connect!(options) do
    Mix.shell().info("Connecting...")
    {:ok, client} = Client.start_link(options)

    try do
      with {:ok, %{name: name, version: {major, minor, build}}} <- Client.read_device_info(client),
           {:ok, %{ads_state: state}} <- Client.read_state(client) do
        Mix.shell().info("Connected to #{name} #{major}.#{minor}.#{build}, in #{state}.")
      else
        {:error, reason} ->
          Mix.raise("The route was added, but connecting failed: #{inspect(reason)}.")
      end
    after
      Client.stop(client)
    end
  end

  # An answer, or what's in brackets: asked, unless given as an option or --yes says to take it,
  # and asked again until there's one that check gives {:ok, value} for.
  defp ask(opts, key, question, default, check \\ &{:ok, &1}) do
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

  defp answer(:eof, _default) do
    Mix.raise(
      "No more input. Run it in a terminal to be asked, or give the PLC, --password and --yes " <>
        "for nothing to be asked"
    )
  end

  defp answer(line, default) do
    case String.trim(line) do
      "" -> default || ""
      answer -> answer
    end
  end

  defp net_id(answer) do
    case NetId.parse(answer) do
      {:ok, _} -> {:ok, answer}
      :error -> {:error, "Not a NetId, such as 10.0.0.7.1.1: #{answer}"}
    end
  end

  # Asked for without showing it, in a terminal that lets its echo be turned off.
  defp password do
    line =
      if Mix.shell() == Mix.Shell.IO,
        do: without_echo(fn -> IO.gets("Password: ") end),
        else: Mix.shell().prompt("Password:")

    case answer(line, nil) do
      "" -> password()
      password -> password
    end
  end

  defp without_echo(fun) do
    case terminal() do
      nil ->
        fun.()

      tty ->
        _ = stty(tty, "-echo")

        try do
          fun.()
        after
          _ = stty(tty, "echo")
          IO.write("\n")
        end
    end
  end

  # The terminal the VM was started from: the VM's own children run without one.
  defp terminal do
    with {:unix, _} <- :os.type(),
         {tty, 0} <- System.cmd("ps", ["-o", "tty=", "-p", System.pid()], stderr_to_stdout: true),
         tty = String.trim(tty),
         true <- tty =~ ~r{^[\w/]+$} and tty not in ["?", "??"] do
      tty
    else
      _ -> nil
    end
  rescue
    _no_ps -> nil
  end

  defp stty(tty, setting),
    do: System.cmd("sh", ["-c", "stty #{setting} < /dev/#{tty}"], stderr_to_stdout: true)

  defp host_name do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  defp udp(opts) do
    for {from, to} <- [udp_port: :port, timeout: :timeout], value = opts[from], do: {to, value}
  end

  defp label(%{name: nil} = device), do: ip(device.address)
  defp label(device), do: "#{device.name} (#{ip(device.address)})"

  defp ip(address), do: address |> :inet.ntoa() |> List.to_string()

  defp option({key, value}) when is_binary(value), do: "#{key}: #{inspect(value)}"
  defp option({key, value}), do: "#{key}: #{value}"
end
