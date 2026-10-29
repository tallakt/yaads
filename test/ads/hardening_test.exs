defmodule ADS.HardeningTest do
  # A router, or something that pretends to be one, that sends what no PLC would. The client must
  # stay up, fail the requests concerned, and connect again when it can't tell where a packet
  # starts.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ADS.Test.Hostile

  alias ADS.{AMS, Client, Command}

  @net_id "5.36.69.176.1.1"
  @state <<0::32, 5::16-little, 0::16>>

  defp scripted(port, opts \\ []) do
    start_supervised!(
      {Client, [host: "127.0.0.1", port: port, net_id: @net_id, timeout: 500] ++ opts},
      id: make_ref()
    )
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else: Process.sleep(10) && eventually(fun, tries - 1)
  end

  test "a frame longer than max_size allows drops the connection, and the client connects again" do
    {listen, port} = listen()
    # long enough between attempts to see why it's down, on a busy machine too
    client = scripted(port, max_size: 1024, backoff: {1000, 1000})
    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    _packet = next_packet(socket)
    :ok = :gen_tcp.send(socket, <<0::16, 1024 + 33::32-little>>)
    assert Task.await(task) == {:error, :closed}
    eventually(fn -> Client.status(client) == {:disconnected, :invalid_frame} end)

    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    answer(socket, next_packet(socket), @state)
    assert {:ok, %{ads_state: :run}} = Task.await(task)
  end

  test "frames of another protocol, and answers to nothing asked, are passed over" do
    {listen, port} = listen()
    client = scripted(port)
    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    packet = next_packet(socket)

    # Reserved bytes other than 0; then an AMS header whose length isn't its data's.
    other = <<1, 0, 4::32-little, "junk">>

    <<tcp::binary-6, header::binary-20, _length::32-little, rest::binary>> =
      AMS.encode(response(packet, @state))

    wrong_length = <<tcp::binary, header::binary, 3::32-little, rest::binary>>
    :ok = :gen_tcp.send(socket, [other, wrong_length])
    answer(socket, packet, @state, invoke_id: packet.invoke_id + 1000)
    answer(socket, packet, @state, state_flags: 0x0007, command: 2)
    answer(socket, packet, @state)
    assert {:ok, %{ads_state: :run}} = Task.await(task)

    # The same answer again is to a request already answered.
    answer(socket, packet, <<0::32, 6::16-little, 0::16>>)
    task = Task.async(fn -> Client.read_state(client) end)
    answer(socket, next_packet(socket), <<0::32, 2::16-little, 0::16>>)
    assert {:ok, %{ads_state: :reset}} = Task.await(task)
  end

  test "an answer that doesn't fit its request is an invalid response" do
    {listen, port} = listen()
    client = scripted(port)
    socket = accept(listen)

    for {request, data} <- [
          # more than asked for, and less than it says it has
          {{:read, 0x4020, 0, 4}, <<0::32, 8::32-little, 0::64>>},
          {{:read, 0x4020, 0, 4}, <<0::32, 4::32-little, 0::16>>},
          {{:read_write, 0xF003, 0, 4, "MAIN.n"}, <<0::32, 5::32-little, 0::40>>},
          {:read_state, <<0::32, 5::16-little>>},
          {:read_device_info, <<0::32, 3, 1>>},
          {{:write, 0x4020, 0, <<1>>}, <<0::32, 1>>},
          {{:delete_notification, 7}, <<>>}
        ] do
      task = Task.async(fn -> Client.request(client, request) end)
      answer(socket, next_packet(socket), data)
      assert Task.await(task) == {:error, {:invalid_response, data}}
    end
  end

  test "an answer that comes a byte at a time comes" do
    {listen, port} = listen()
    # a byte a millisecond, which a busy machine can make far slower
    client = scripted(port, timeout: 30_000)
    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    trickle(socket, AMS.encode(response(next_packet(socket), @state)))
    assert {:ok, %{ads_state: :run}} = Task.await(task, 35_000)
  end

  test "a trickle of bytes that never makes a packet doesn't keep a dead connection open" do
    {listen, port} = listen()
    client = scripted(port, timeout: 100, backoff: {10, 10})
    socket = accept(listen)

    {:ok, _trickler} =
      Task.start_link(fn -> trickle(socket, <<0::16, 1000::32-little, 0::8000>>, 10) end)

    assert Client.read_state(client) == {:error, :timeout}
    assert Client.read_state(client) == {:error, :timeout}
    _again = accept(listen)
  end

  test "samples for handles the client never had: it deletes each once, up to a limit" do
    {listen, port} = listen()
    client = scripted(port, timeout: 5000)
    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    packet = next_packet(socket)

    samples = for handle <- 1..1500, do: {handle, <<1>>}
    notification = Command.encode_notification([{nil, samples}, {nil, Enum.take(samples, 10)}])
    :ok = :gen_tcp.send(socket, AMS.encode(request(packet, 8, notification)))

    # a thousand, however long they take, and no more
    deletes =
      for _ <- 1..1000 do
        assert %AMS{command: 7} = delete = next_packet(socket, 5000)
        answer(socket, delete, <<0::32>>)
        delete
      end

    assert drain(socket, fn %AMS{command: 7} -> <<0::32>> end) == []
    handles = for %AMS{data: <<handle::32-little>>} <- deletes, do: handle
    assert handles == Enum.uniq(handles)

    answer(socket, packet, @state)
    assert {:ok, _} = Task.await(task)
  end

  test "requests sent to the client, many at once, are each refused" do
    {listen, port} = listen()
    client = scripted(port)
    socket = accept(listen)
    task = Task.async(fn -> Client.read_state(client) end)
    packet = next_packet(socket)

    requests = for i <- 1..200, do: AMS.encode(request(packet, 2, <<0::96>>, invoke_id: i))
    elsewhere = AMS.encode(request(packet, 2, <<0::96>>, target_port: packet.source_port + 1))
    :ok = :gen_tcp.send(socket, [requests, elsewhere])
    refused = drain(socket)

    assert for(
             %AMS{error_code: 0x701, state_flags: 5, command: 2, invoke_id: i} <- refused,
             do: i
           ) == Enum.to_list(1..200)

    answer(socket, packet, @state)
    assert {:ok, _} = Task.await(task)
  end

  test "a connection that goes while its packets are handled leaves the client up" do
    {listen, port} = listen()

    {:ok, client} =
      Client.start_link(
        host: "127.0.0.1",
        port: port,
        net_id: @net_id,
        timeout: 500,
        backoff: {10, 10}
      )

    for _ <- 1..20 do
      socket = accept(listen)
      task = Task.async(fn -> Client.read_state(client) end)
      packet = next_packet(socket)
      requests = for i <- 1..50, do: AMS.encode(request(packet, 2, <<0::96>>, invoke_id: i))
      :ok = :gen_tcp.send(socket, requests)
      reset(socket)
      assert {:error, _} = Task.await(task)
    end

    Client.stop(client)
  end

  # Anything at all; or AMS packets, whole or cut short, of any command and flags, some of them
  # answers to the request waiting, with data of any kind; or notifications for any handles.
  defp garbage do
    frame =
      one_of([
        tuple({constant(:raw), binary(max_length: 64)}),
        gen all command <- integer(0..10),
                flags <- member_of([0, 4, 5, 7, 0xFFFF]),
                invoke <- one_of([constant(:asked), integer(0..5)]),
                error <- frequency([{3, constant(0)}, {1, integer(0..0xFFFF)}]),
                data <- binary(max_length: 48),
                skew <- frequency([{3, constant(0)}, {1, integer(-40..8)}]) do
          {:frame, command, flags, invoke, error, data, skew}
        end,
        gen all samples <- list_of(tuple({integer(0..5), binary(max_length: 8)}), max_length: 4) do
          {:notification, samples}
        end
      ])

    list_of(frame, min_length: 1, max_length: 6)
  end

  defp garbage_bytes(frames, packet),
    do: for(frame <- frames, into: <<>>, do: bytes(frame, packet))

  defp bytes({:raw, bytes}, _packet), do: bytes

  defp bytes({:frame, command, flags, invoke, error, data, skew}, packet) do
    invoke = if invoke == :asked, do: packet.invoke_id, else: invoke
    fields = [command: command, state_flags: flags, invoke_id: invoke, error_code: error]
    ams = AMS.encode(response(packet, data, fields), :tls)
    <<0::16, max(byte_size(ams) + skew, 0)::32-little, ams::binary>>
  end

  defp bytes({:notification, samples}, packet),
    do: AMS.encode(request(packet, 8, Command.encode_notification([{nil, samples}])))

  property "garbage, of any kind, never takes the client down" do
    check all frames <- garbage(), max_runs: 40 do
      {listen, port} = listen()

      {:ok, client} =
        Client.start_link(
          host: "127.0.0.1",
          port: port,
          net_id: @net_id,
          timeout: 100,
          backoff: {10, 10}
        )

      socket = accept(listen)
      task = Task.async(fn -> Client.read_state(client) end)
      packet = next_packet(socket)
      :ok = :gen_tcp.send(socket, garbage_bytes(frames, packet))

      result = Task.await(task)
      assert match?({:ok, %{ads_state: _}}, result) or match?({:error, _}, result)
      status = Client.status(client)
      assert status in [:connected, :connecting] or match?({:disconnected, _}, status)

      Client.stop(client)
      :gen_tcp.close(listen)
    end
  end
end
