defmodule ADS.Test.Hostile do
  @moduledoc false
  # A router played by a test, a packet at a time, to answer as no PLC would: late, wrong, a byte
  # at a time, with garbage, or not at all.

  alias ADS.AMS

  def listen do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  def accept(listen, timeout \\ 2000) do
    {:ok, socket} = :gen_tcp.accept(listen, timeout)
    socket
  end

  # The next packet from the client, or {:error, reason}.
  def next_packet(socket, timeout \\ 2000) do
    with {:ok, <<0::16, length::32-little>>} <- :gen_tcp.recv(socket, 6, timeout),
         {:ok, ams} <- :gen_tcp.recv(socket, length, timeout),
         {:ok, packet, ""} <- AMS.decode(<<0::16, length::32-little, ams::binary>>) do
      packet
    end
  end

  # The packets the client sends until it's quiet for `timeout`, each answered by `answer`, a
  # function of the packet that gives the data of its answer, or nil for none.
  def drain(socket, answer \\ fn _ -> nil end, timeout \\ 300, packets \\ []) do
    case next_packet(socket, timeout) do
      %AMS{} = packet ->
        if data = answer.(packet), do: answer(socket, packet, data)
        drain(socket, answer, timeout, [packet | packets])

      {:error, _reason} ->
        Enum.reverse(packets)
    end
  end

  # The answer to a packet the client sent, with `fields` of the AMS header to change.
  def response(packet, data, fields \\ []) do
    struct(
      %AMS{
        target: packet.source,
        target_port: packet.source_port,
        source: packet.target,
        source_port: packet.target_port,
        command: packet.command,
        state_flags: AMS.response_flags(),
        invoke_id: packet.invoke_id,
        data: data
      },
      fields
    )
  end

  def answer(socket, packet, data, fields \\ []),
    do: :ok = :gen_tcp.send(socket, AMS.encode(response(packet, data, fields)))

  # A request to the client, as a device would send one, addressed by a packet the client sent.
  def request(packet, command, data, fields \\ []) do
    struct(
      %AMS{
        target: packet.source,
        target_port: packet.source_port,
        source: packet.target,
        source_port: packet.target_port,
        command: command,
        state_flags: AMS.request_flags(),
        data: data
      },
      fields
    )
  end

  # Bytes sent one at a time, `pause` ms apart.
  def trickle(socket, bytes, pause \\ 1) do
    for <<byte <- bytes>> do
      Process.sleep(pause)
      :gen_tcp.send(socket, <<byte>>)
    end

    :ok
  end

  # Closes with a reset, as a router that goes away does, rather than TCP's orderly close.
  def reset(socket) do
    :ok = :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
  end
end
