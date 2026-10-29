defmodule ADS.TwinCATDiscoveryTest do
  # Against a real PLC over UDP, and only when asked, as test/twincat/README.md says; these need
  # no route, and one of them adds one:
  #
  #   * TWINCAT_SEARCH - 1, if the PLC is on this machine's network, for a broadcast search
  #   * TWINCAT_PASSWORD - of the PLC's Administrator, or of TWINCAT_USER, to add a route named
  #     yaads-test for this machine, which stays
  use ExUnit.Case, async: false

  alias ADS.{Client, Discovery}

  @moduletag :twincat

  defp env!(name), do: System.get_env(name) || raise("#{name} must be set for the TwinCAT tests")

  test "the PLC's NetId, asked over UDP" do
    assert {:ok, %{net_id: net_id}} = Discovery.info(env!("TWINCAT_HOST"))
    assert net_id == env!("TWINCAT_NET_ID")
  end

  @tag skip: if(System.get_env("TWINCAT_SEARCH") != "1", do: "TWINCAT_SEARCH=1 to search")
  test "a broadcast search finds the PLC" do
    assert {:ok, devices} = Discovery.search()
    assert Enum.any?(devices, &(&1.net_id == env!("TWINCAT_NET_ID")))
  end

  @tag skip: if(System.get_env("TWINCAT_PASSWORD") == nil, do: "TWINCAT_PASSWORD to add a route")
  test "a route, added with the PLC's password, lets a client in" do
    host = env!("TWINCAT_HOST")
    user = System.get_env("TWINCAT_USER", "Administrator")
    local = if net_id = System.get_env("TWINCAT_LOCAL_NET_ID"), do: [net_id: net_id], else: []

    assert {:error, _wrong} =
             Discovery.add_route(host, [user: user, password: "not the password"] ++ local)

    assert Discovery.add_route(
             host,
             [user: user, password: env!("TWINCAT_PASSWORD"), name: "yaads-test"] ++ local
           ) == :ok

    client =
      start_supervised!(
        {Client,
         [host: host, net_id: env!("TWINCAT_NET_ID")] ++
           Enum.map(local, fn {:net_id, id} -> {:local_net_id, id} end)}
      )

    assert {:ok, %{ads_state: :run}} = Client.read_state(client)
  end
end
