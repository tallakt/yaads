defmodule ADS.WiresharkTest do
  # The client's packets against another's reading of them: Wireshark's dissector of AMS, run by
  # rawshark on frames of TCP to port 48898, and only when asked, as test/wireshark/README.md
  # says. Each packet must read the same to Wireshark, field by field, as it was meant, and none
  # may be malformed. Wireshark is run as a tool; nothing of it is read or included.
  #
  # Wireshark 4.2 doesn't dissect UDP port 48899, so discovery isn't here; of a notification it
  # reads only the number of its stamps; and a response to a read or read-write with less than 2
  # bytes of data it reads only as far as its AMS header. It reads a TCP segment as one packet at
  # its start, neither reassembling packets cut across segments nor reading on to the next in the
  # same; so each packet goes in a segment of its own.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ADS.{AMS, Client, Command, NetId, Sum}
  alias ADS.Test.FakePLC

  @moduletag :wireshark

  @fields ~w(
    ams.targetnetid ams.targetport ams.sendernetid ams.senderport ams.cmdid ams.stateflags
    ams.cbdata ams.errorcode ams.invokeid ams.ads_indexgroup ams.ads_indexoffset ams.ads_cblength
    ams.ads_cbreadlength ams.ads_cbwritelength ams.adsresult ams.ads_state ams.ads_devicestate
    ams.ads_notificationhandle ams.ads_transmode ams.ads_maxdelay ams.ads_cycletime
    ams.ads_noteblocksstamps ams.ads_devicename ams.ads_versionversion ams.ads_versionrevision
    ams.ads_versionbuild _ws.malformed _ws.expert.severity
  )

  @client {<<10, 0, 0, 7>>, 50_000}
  @plc {<<10, 0, 0, 5>>, 48_898}

  defp u32, do: integer(0..0xFFFFFFFF)

  defp request do
    one_of([
      constant(:read_device_info),
      constant(:read_state),
      gen(all g <- u32(), o <- u32(), l <- integer(0..64), do: {:read, g, o, l}),
      gen(all g <- u32(), o <- u32(), d <- binary(max_length: 16), do: {:write, g, o, d}),
      gen(
        all state <- member_of([:run, :stop, :reset, 0, 65535]),
            device_state <- integer(0..65535),
            data <- binary(max_length: 8),
            do: {:write_control, state, device_state, data}
      ),
      gen(
        all g <- u32(),
            o <- u32(),
            l <- u32(),
            mode <- member_of([:on_change, :cyclic]),
            delay <- u32(),
            cycle <- u32(),
            do: {:add_notification, g, o, l, mode, delay, cycle}
      ),
      map(u32(), &{:delete_notification, &1}),
      gen(
        all g <- u32(),
            o <- u32(),
            l <- u32(),
            d <- binary(max_length: 16),
            do: {:read_write, g, o, l, d}
      )
    ])
  end

  defp header do
    gen all target <- binary(length: 6),
            target_port <- integer(0..65535),
            source <- binary(length: 6),
            source_port <- integer(0..65535),
            invoke_id <- u32() do
      %AMS{
        target: target,
        target_port: target_port,
        source: source,
        source_port: source_port,
        invoke_id: invoke_id
      }
    end
  end

  property "any request the client encodes reads to Wireshark as it was meant" do
    check all requests <- list_of(tuple({header(), request()}), length: 50), max_runs: runs() do
      packets =
        for {%AMS{} = header, request} <- requests do
          {command, data} = Command.encode_request(request)
          {%AMS{header | command: command, state_flags: AMS.request_flags(), data: data}, request}
        end

      dissected = dissect(Enum.map(packets, &elem(&1, 0)))

      for {{packet, request}, fields} <- Enum.zip(packets, dissected) do
        assert_read(fields, Map.merge(header(packet), meant(request)), request)
      end
    end
  end

  property "a notification as the fake PLC sends it, with however many stamps" do
    stamps =
      list_of(
        tuple({
          map(integer(0..2_650_467_743_999_999_999), &Command.from_filetime/1),
          list_of(tuple({u32(), binary(max_length: 12)}), min_length: 1, max_length: 4)
        }),
        min_length: 1,
        max_length: 4
      )

    check all stamps <- list_of(stamps, length: 20), max_runs: runs() do
      packets =
        for stamps <- stamps do
          %AMS{
            target: <<10, 0, 0, 7, 1, 1>>,
            target_port: 32_905,
            source: FakePLC.net_id(),
            source_port: 851,
            command: 8,
            data: Command.encode_notification(stamps)
          }
        end

      for {{packet, stamps}, fields} <- Enum.zip(Enum.zip(packets, stamps), dissect(packets)) do
        assert_read(
          fields,
          Map.put(header(packet), "ams.ads_noteblocksstamps", length(stamps)),
          stamps
        )
      end
    end
  end

  test "sum commands, as read-writes of 0xF080 to 0xF082" do
    requests = [
      Sum.read([{0x4040, 0, 4}, {0x4040, 8, 2}]),
      Sum.write([{0x4040, 0, <<1, 2, 3, 4>>}, {0x4040, 8, <<5, 6>>}]),
      Sum.read_write([{0xF003, 0, 4, "MAIN.nSpeed\0"}, {0xF003, 0, 4, "MAIN.bOn\0"}])
    ]

    packets =
      for {request, invoke_id} <- Enum.with_index(requests, 1) do
        {command, data} = Command.encode_request(request)

        %AMS{
          target: FakePLC.net_id(),
          target_port: 851,
          source: <<10, 0, 0, 7, 1, 1>>,
          source_port: 32_905,
          command: command,
          state_flags: AMS.request_flags(),
          invoke_id: invoke_id,
          data: data
        }
      end

    for {{packet, request}, fields} <- Enum.zip(Enum.zip(packets, requests), dissect(packets)) do
      assert_read(fields, Map.merge(header(packet), meant(request)), request)
    end
  end

  # A client's session with the fake PLC, every packet both ways as it went: the client's
  # requests, and the fake's answers and notifications.
  test "a session of the client with the fake PLC, both ways, reads to Wireshark as it went" do
    plc = start_supervised!(FakePLC)
    port = recorder(FakePLC.port(plc))

    client =
      start_supervised!(
        {Client, host: "127.0.0.1", port: port, net_id: NetId.to_string(FakePLC.net_id())},
        restart: :temporary
      )

    assert {:ok, _} = Client.read_device_info(client)
    assert {:ok, _} = Client.read_state(client)

    assert Client.write(client, "MAIN.nSpeed", 3) == :ok
    assert {:ok, %{"nSpeed" => 0}} = Client.read(client, "MAIN.stPump")
    assert {:ok, _} = Client.read_many(client, ["MAIN.nSpeed", "MAIN.bOn", "MAIN.nNone"])
    assert {:ok, _} = Client.write_many(client, [{"MAIN.nSpeed", 5}, {"MAIN.bOn", true}])
    assert {:ok, ref} = Client.subscribe(client, ["MAIN.nCounter", "MAIN.fTemp"])
    :ok = FakePLC.put(plc, "MAIN.nCounter", 9)
    assert_receive {Client, ^ref, {:value, "MAIN.nCounter", 9, _}}
    assert :ok = Client.unsubscribe(client, ref)
    assert {:ok, _} = Client.symbols(client)
    assert {:ok, _} = Client.data_types(client)
    assert :ok = Client.write_control(client, :run)
    assert {:error, _} = Client.read(client, {0x1234, 0}, type: :int)
    :ok = Client.stop(client)

    chunks = recorded()

    for way <- [:up, :down] do
      packets = packets(for {^way, data} <- chunks, into: <<>>, do: data)

      for {packet, fields} <- Enum.zip(packets, dissect(packets, way)) do
        assert_read(fields, Map.merge(header(packet), layout(packet)), packet)
      end

      commands = packets |> Enum.map(& &1.command) |> Enum.uniq() |> Enum.sort()

      assert commands ==
               if(way == :up, do: [1, 2, 3, 4, 5, 6, 7, 9], else: [1, 2, 3, 4, 5, 6, 7, 8, 9])
    end
  end

  defp packets(""), do: []

  defp packets(bytes) do
    {:ok, packet, rest} = AMS.decode(bytes, :tcp)
    [packet | packets(rest)]
  end

  defp runs, do: Application.get_env(:stream_data, :max_runs, 100) |> div(10) |> max(5)

  # What every packet's AMS header reads as.
  defp header(packet) do
    %{
      "ams.targetnetid" => NetId.to_string(packet.target),
      "ams.targetport" => packet.target_port,
      "ams.sendernetid" => NetId.to_string(packet.source),
      "ams.senderport" => packet.source_port,
      "ams.cmdid" => packet.command,
      "ams.stateflags" => packet.state_flags,
      "ams.cbdata" => byte_size(packet.data),
      "ams.errorcode" => packet.error_code,
      "ams.invokeid" => packet.invoke_id
    }
  end

  # What a request was meant to say, as the client was asked to send it.
  defp meant(:read_device_info), do: %{}
  defp meant(:read_state), do: %{}
  defp meant({:read, g, o, l}), do: address(g, o) |> Map.put("ams.ads_cblength", l)
  defp meant({:write, g, o, d}), do: address(g, o) |> Map.put("ams.ads_cblength", byte_size(d))

  defp meant({:write_control, state, device_state, data}) do
    %{
      "ams.ads_state" => ADS.state_code(state),
      "ams.ads_devicestate" => device_state,
      "ams.ads_cblength" => byte_size(data)
    }
  end

  defp meant({:add_notification, g, o, l, mode, delay, cycle}) do
    Map.merge(address(g, o), %{
      "ams.ads_cblength" => l,
      "ams.ads_transmode" => %{on_change: 4, cyclic: 3}[mode],
      "ams.ads_maxdelay" => delay,
      "ams.ads_cycletime" => cycle
    })
  end

  defp meant({:delete_notification, handle}), do: %{"ams.ads_notificationhandle" => handle}

  defp meant({:read_write, g, o, l, d}) do
    Map.merge(address(g, o), %{
      "ams.ads_cbreadlength" => l,
      "ams.ads_cbwritelength" => byte_size(d)
    })
  end

  defp address(group, offset),
    do: %{"ams.ads_indexgroup" => group, "ams.ads_indexoffset" => offset}

  # What a packet of the session says, by the layouts of Beckhoff's documentation: a request's
  # fields, or a response's result and what follows it.
  defp layout(%AMS{command: 8, data: <<_length::32-little, count::32-little, _::binary>>}),
    do: %{"ams.ads_noteblocksstamps" => count}

  defp layout(%AMS{state_flags: 0x0004, command: command, data: data}) do
    case {command, data} do
      {2, <<g::32-little, o::32-little, l::32-little>>} ->
        meant({:read, g, o, l})

      {3, <<g::32-little, o::32-little, l::32-little, d::binary-size(l)>>} ->
        meant({:write, g, o, d})

      {5, <<s::16-little, ds::16-little, l::32-little, d::binary-size(l)>>} ->
        meant({:write_control, s, ds, d})

      {6,
       <<g::32-little, o::32-little, l::32-little, m::32-little, delay::32-little,
         cycle::32-little, _::binary-16>>} ->
        meant({:add_notification, g, o, l, %{4 => :on_change, 3 => :cyclic}[m], delay, cycle})

      {7, <<handle::32-little>>} ->
        meant({:delete_notification, handle})

      {9, <<g::32-little, o::32-little, r::32-little, l::32-little, d::binary-size(l)>>} ->
        meant({:read_write, g, o, r, d})

      {command, <<>>} when command in [1, 4] ->
        %{}
    end
  end

  defp layout(%AMS{state_flags: 0x0005, command: command, data: data}) do
    case {command, data} do
      {1, <<0::32, major, minor, build::16-little, name::binary-16>>} ->
        %{
          "ams.adsresult" => 0,
          "ams.ads_versionversion" => major,
          "ams.ads_versionrevision" => minor,
          "ams.ads_versionbuild" => build,
          "ams.ads_devicename" => name |> :binary.split(<<0>>) |> hd()
        }

      {command, <<_result::32-little, length::32-little, _::binary-size(length)>>}
      when command in [2, 9] and length < 2 ->
        %{}

      {command, <<result::32-little, length::32-little, _::binary-size(length)>>}
      when command in [2, 9] ->
        %{"ams.adsresult" => result, "ams.ads_cblength" => length}

      {4, <<0::32, state::16-little, device_state::16-little>>} ->
        %{"ams.adsresult" => 0, "ams.ads_state" => state, "ams.ads_devicestate" => device_state}

      {6, <<result::32-little, handle::32-little>>} ->
        %{"ams.adsresult" => result, "ams.ads_notificationhandle" => handle}

      {_command, <<result::32-little>>} ->
        %{"ams.adsresult" => result}
    end
  end

  defp assert_read(fields, meant, what) do
    refute fields["_ws.malformed"], "malformed to Wireshark: #{inspect(what)}"
    refute fields["_ws.expert.severity"], "Wireshark's expert info on #{inspect(what)}"

    for {field, value} <- meant do
      assert fields[field] == [value], "#{field} of #{inspect(what)}: #{inspect(fields[field])}"
    end
  end

  ## rawshark

  # Each packet in a TCP segment of its own, up from the client or down from the PLC, and what
  # Wireshark reads of each.
  defp dissect(packets, way \\ :up) do
    {from, to} = if way == :up, do: {@client, @plc}, else: {@plc, @client}
    segments = Enum.map(packets, &AMS.encode/1)
    {frames, _seq} = Enum.map_reduce(segments, 1, &{frame(from, to, &2, &1), &2 + byte_size(&1)})
    pcap = Path.join(System.tmp_dir!(), "yaads-#{System.unique_integer([:positive])}.pcap")
    File.write!(pcap, pcap(frames))

    try do
      rawshark = System.get_env("RAWSHARK", "rawshark")

      executable =
        System.find_executable(rawshark) || raise "#{rawshark} not found; RAWSHARK gives another"

      args = ["-s", "-r", "-", "-d", "encap:1", "-n"] ++ Enum.flat_map(@fields, &["-F", &1])
      # rawshark reads a pipe, not a file: the shell gives it the file as its standard input.
      {out, 0} =
        System.cmd("sh", ["-c", ~s(exec "$0" "$@" < "$PCAP") | [executable | args]],
          env: [{"PCAP", pcap}]
        )

      [_types | lines] = String.split(out, "\n", trim: true)
      assert length(lines) == length(packets)
      Enum.map(lines, &fields/1)
    after
      File.rm(pcap)
    end
  end

  # A line of rawshark's: the frame's number, then each field's index and value, quoted, for as
  # many times as it's there.
  defp fields(line) do
    for [_, index, value] <- Regex.scan(~r/(\d+)="([^"]*)"/, line), reduce: %{} do
      fields ->
        field = Enum.at(@fields, String.to_integer(index))
        Map.update(fields, field, [value(value)], &(&1 ++ [value(value)]))
    end
  end

  defp value("0x" <> hex), do: String.to_integer(hex, 16)

  defp value(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> value
    end
  end

  # An Ethernet frame of IPv4 and TCP, with the segment given; Wireshark checks no checksums.
  defp frame({source, source_port}, {target, target_port}, seq, segment) do
    tcp =
      <<source_port::16, target_port::16, seq::32, 1::32, 5::4, 0::4, 0x18, 65535::16, 0::16,
        0::16, segment::binary>>

    ip =
      <<4::4, 5::4, 0, 20 + byte_size(tcp)::16, 0::16, 0::16, 64, 6, 0::16, source::binary,
        target::binary>>

    <<2, 0, 0, 0, 0, 2, 2, 0, 0, 0, 0, 1, 0x0800::16, ip::binary, tcp::binary>>
  end

  defp pcap(frames) do
    records =
      for frame <- frames, into: <<>> do
        <<0::32, 0::32, byte_size(frame)::32-little, byte_size(frame)::32-little, frame::binary>>
      end

    <<0xA1B2C3D4::32-little, 2::16-little, 4::16-little, 0::32, 0::32, 262_144::32-little,
      1::32-little, records::binary>>
  end

  ## A recorder: a proxy in front of the fake PLC, which keeps what goes each way

  defp recorder(upstream) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    test = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      {:ok, plc} = :gen_tcp.connect(~c"127.0.0.1", upstream, [:binary, active: false])
      :ok = :inet.setopts(client, active: true)
      :ok = :inet.setopts(plc, active: true)
      relay(client, plc, [], test)
    end)

    port
  end

  defp relay(client, plc, chunks, test) do
    receive do
      {:tcp, ^client, data} ->
        :ok = :gen_tcp.send(plc, data)
        relay(client, plc, [{:up, data} | chunks], test)

      {:tcp, ^plc, data} ->
        _ = :gen_tcp.send(client, data)
        relay(client, plc, [{:down, data} | chunks], test)

      {:tcp_closed, _socket} ->
        :gen_tcp.close(client)
        :gen_tcp.close(plc)
        send(test, {:recorded, Enum.reverse(chunks)})
    end
  end

  defp recorded do
    receive do
      {:recorded, chunks} -> chunks
    after
      5000 -> flunk("the session didn't end")
    end
  end
end
