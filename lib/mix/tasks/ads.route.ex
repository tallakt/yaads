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
    * `--delete` - delete the route rather than add it; the route of the name, which TwinCAT
      deletes by, as it was added. If the PLC doesn't answer this machine over ADS, it has no
      route for it, and nothing is asked or deleted; if it does, the login and name are asked for
      as when adding, and it is to answer no more after, or the removal failed, as TwinCAT's
      answer doesn't tell
    * `--timeout` - how long to wait for answers over UDP, in ms (default 2000 for the search,
      5000 otherwise)
    * `--tcp-port`, `--udp-port`, `--ams-port` - if not 48898, 48899 and 851
    * `--codepage` - of the PLC's strings, such as `windows-1251`, if not Windows-1252 (see
      `ADS.Codepage`)
  """

  use Mix.Task

  import Mix.ADS

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
    ams_port: :integer,
    codepage: :string
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
    if opts[:delete],
      do: delete!(device, local_net_id, opts),
      else: add!(device, local_net_id, opts)
  end

  defp add!(device, local_net_id, opts) do
    {user, password} = login(opts)
    net_id = ask(opts, :net_id, "This machine's NetId", local_net_id, &net_id/1)
    route = route(opts, user, password, net_id)

    Mix.shell().info("Adding a route on #{label(device)}...")
    route!(&Discovery.add_route/2, device, route)
    client = client(device, if(net_id != local_net_id, do: net_id), opts)
    if Keyword.get(opts, :connect, true), do: connect!(client)

    Mix.shell().info("""

        {:ok, plc} = ADS.Client.start_link(#{Enum.map_join(client, ", ", &option/1)})
    """)
  end

  defp login(opts), do: {ask(opts, :user, "User", "Administrator"), opts[:password] || password()}

  # The route, its name asked for last.
  defp route(opts, user, password, net_id) do
    name = ask(opts, :name, "Route name", host_name())

    [user: user, password: password, net_id: net_id, name: name] ++
      Keyword.take(opts, [:address]) ++ udp(opts)
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

  # The route deleted, with the device answering this machine over ADS before, and not after: what
  # TwinCAT answers to the delete doesn't tell, as 3.1 4026 answers :device_error for a route it
  # hasn't, and at times for one it deletes.
  # So the login and the name are asked for only if there's a route for this machine to delete.
  defp delete!(device, local_net_id, opts) do
    net_id = ask(opts, :net_id, "This machine's NetId", local_net_id, &net_id/1)
    client = client(device, if(net_id != local_net_id, do: net_id), opts)

    case answers(client) do
      :ok ->
        {user, password} = login(opts)
        delete_route!(device, route(opts, user, password, net_id), client)

      {:error, _reason} ->
        Mix.shell().info(
          "#{label(device)} has no route for this machine (#{net_id}): nothing to delete."
        )
    end
  end

  defp delete_route!(device, route, client) do
    Mix.shell().info("Deleting the route #{route[:name]} on #{label(device)}...")
    answer = route(&Discovery.delete_route/2, device, route)

    case {answer, gone?(client)} do
      {answer, true} when answer in [:ok, {:error, :device_error}] ->
        Mix.shell().info("Deleted.")

      {answer, false} when answer in [:ok, {:error, :device_error}] ->
        fail!(
          device,
          {:error, :not_deleted},
          "Removal failed: it answered #{inspect(answer)}, and answers this machine still. " <>
            "Is its route named otherwise? --list shows them."
        )

      {error, _gone} ->
        fail!(device, error)
    end
  end

  # Whether the device answers no more, on a new connection, given a moment to.
  defp gone?(client, tries \\ 3) do
    case answers(client) do
      {:error, _reason} ->
        true

      :ok when tries > 1 ->
        Process.sleep(200)
        gone?(client, tries - 1)

      :ok ->
        false
    end
  end

  # Whether the device answers this machine, over a connection of its own: its system service
  # answers its state to any client it has a route for, PLC running or not.
  defp answers(options) do
    {:ok, client} = Client.start_link(options)

    try do
      with {:ok, _state} <- Client.read_state(client, port: 10_000), do: :ok
    after
      Client.stop(client)
    end
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

  defp option({key, value}) when is_binary(value) or is_atom(value),
    do: "#{key}: #{inspect(value)}"

  defp option({key, value}), do: "#{key}: #{value}"
end
