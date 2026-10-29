defmodule ADS.FuzzTest do
  # Whatever comes from a device, or from something that only says it is one, decodes to a value
  # or to an error, and never raises; what encodes decodes again to what it was.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ADS.{AMS, Command, DataType, Discovery, NetId, ReturnCode, Secure, Sum, Symbol, Type}

  defp u32, do: integer(0..0xFFFFFFFF)

  ## AMS

  defp packet do
    gen all target <- binary(length: 6),
            target_port <- integer(0..65535),
            source <- binary(length: 6),
            source_port <- integer(0..65535),
            command <- integer(0..65535),
            state_flags <- integer(0..65535),
            error_code <- u32(),
            invoke_id <- u32(),
            data <- binary(max_length: 64) do
      %AMS{
        target: target,
        target_port: target_port,
        source: source,
        source_port: source_port,
        command: command,
        state_flags: state_flags,
        error_code: error_code,
        invoke_id: invoke_id,
        data: data
      }
    end
  end

  property "an AMS packet decodes to itself, over TCP and inside TLS" do
    check all packet <- packet(),
              framing <- member_of([:tcp, :tls]),
              rest <- binary(max_length: 8) do
      assert AMS.decode(AMS.encode(packet, framing) <> rest, framing) == {:ok, packet, rest}
    end
  end

  property "packets cut anywhere decode the same, as they come over a connection" do
    check all packets <- list_of(packet(), max_length: 5),
              framing <- member_of([:tcp, :tls]),
              cuts <- list_of(integer(1..80), max_length: 10) do
      stream = for packet <- packets, into: <<>>, do: AMS.encode(packet, framing)
      assert receive_all(chunks(stream, cuts), framing) == packets
    end
  end

  defp chunks(bytes, []), do: [bytes]
  defp chunks(bytes, [cut | _]) when cut >= byte_size(bytes), do: [bytes]

  defp chunks(bytes, [cut | cuts]),
    do: [
      binary_part(bytes, 0, cut) | chunks(binary_part(bytes, cut, byte_size(bytes) - cut), cuts)
    ]

  defp receive_all(chunks, framing) do
    {packets, ""} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {packets, buffer} ->
        take(buffer <> chunk, framing, packets)
      end)

    Enum.reverse(packets)
  end

  defp take(buffer, framing, packets) do
    case AMS.decode(buffer, framing) do
      {:ok, packet, rest} -> take(rest, framing, [packet | packets])
      :more -> {packets, buffer}
    end
  end

  property "any bytes decode to a packet, a frame to pass over, the start of one, or an error" do
    check all bytes <- one_of([binary(), map(binary(), &(<<0, 0>> <> &1))]),
              framing <- member_of([:tcp, :tls]),
              max_data <- one_of([constant(64), constant(16 * 1024 * 1024)]) do
      case AMS.decode(bytes, framing, max_data) do
        {:ok, %AMS{} = packet, rest} ->
          assert byte_size(packet.data) <= max_data
          assert String.ends_with?(bytes, rest) and byte_size(rest) < byte_size(bytes)

        {:discard, rest} ->
          assert String.ends_with?(bytes, rest) and byte_size(rest) < byte_size(bytes)

        result ->
          assert result in [:more, {:error, :invalid_length}]
      end
    end
  end

  ## Commands

  defp request do
    one_of([
      constant(:read_device_info),
      constant(:read_state),
      gen(
        all(
          group <- u32(),
          offset <- u32(),
          length <- integer(0..16),
          do: {:read, group, offset, length}
        )
      ),
      gen(
        all(
          group <- u32(),
          offset <- u32(),
          data <- binary(max_length: 8),
          do: {:write, group, offset, data}
        )
      ),
      gen(
        all(
          state <- member_of([:run, :stop]),
          data <- binary(max_length: 4),
          do: {:write_control, state, 0, data}
        )
      ),
      gen(
        all(
          group <- u32(),
          length <- integer(0..16),
          do: {:add_notification, group, 0, length, :on_change, 0, 0}
        )
      ),
      map(u32(), &{:delete_notification, &1}),
      gen(
        all(
          group <- u32(),
          length <- integer(0..16),
          data <- binary(max_length: 8),
          do: {:read_write, group, 0, length, data}
        )
      )
    ])
  end

  property "any answer to a request is its result or an error" do
    check all request <- request(),
              data <-
                one_of([binary(max_length: 40), map(binary(max_length: 40), &(<<0::32>> <> &1))]) do
      {command, _data} = Command.encode_request(request)
      assert command == Command.command_id(request)

      case Command.decode_response(request, data) do
        :ok -> assert data == <<0::32>>
        {:ok, _result} -> :ok
        {:error, {:invalid_response, ^data}} -> :ok
        {:error, error} -> assert is_atom(error) or is_integer(error)
      end
    end
  end

  defp stamps do
    # Up to the end of year 9999, as far as DateTime goes.
    filetime = integer(0..2_650_467_743_999_999_999)
    samples = list_of(tuple({u32(), binary(max_length: 12)}), max_length: 4)
    list_of(tuple({map(filetime, &Command.from_filetime/1), samples}), max_length: 4)
  end

  property "a device notification decodes to its stamps" do
    check all stamps <- stamps() do
      assert Command.decode_notification(Command.encode_notification(stamps)) == {:ok, stamps}
    end
  end

  property "any bytes of a device notification decode to stamps or an error" do
    filetime = integer(0..0xFFFFFFFFFFFFFFFF)

    check all bytes <-
                one_of([
                  binary(),
                  map(stamps(), &Command.encode_notification/1),
                  map(stamps(), &corrupt(Command.encode_notification(&1)))
                ]),
              time <- filetime do
      assert Command.from_filetime(time) == nil or
               match?(%DateTime{}, Command.from_filetime(time))

      case Command.decode_notification(bytes) do
        {:ok, stamps} -> assert is_list(stamps)
        :error -> :ok
      end
    end
  end

  # The bytes, one of them changed.
  defp corrupt(<<>>), do: <<>>

  defp corrupt(bytes) do
    at = :rand.uniform(byte_size(bytes)) - 1
    <<before::binary-size(at), byte, rest::binary>> = bytes
    <<before::binary, Bitwise.bxor(byte, :rand.uniform(255)), rest::binary>>
  end

  ## Sum commands

  defp reads, do: list_of(tuple({u32(), u32(), integer(0..8)}), min_length: 1, max_length: 5)

  property "sum reads decode to each one's result" do
    check all reads <- reads(),
              results <- list_of(member_of([0, 0x703, 0x710]), length: length(reads)) do
      {:read_write, 0xF080, n, length, _headers} = Sum.read(reads)
      assert n == length(reads)
      data = for({_, _, size} <- reads, into: <<>>, do: :binary.copy(<<7>>, size))
      response = for(result <- results, into: <<>>, do: <<result::32-little>>) <> data
      assert byte_size(response) == length
      assert {:ok, decoded} = Sum.decode_read(reads, response)

      for {{_, _, size}, result, decoded} <- Enum.zip([reads, results, decoded]) do
        assert decoded ==
                 if(result == 0,
                   do: {:ok, :binary.copy(<<7>>, size)},
                   else: {:error, ReturnCode.name(result)}
                 )
      end
    end
  end

  property "any answer to a sum command is its results or an invalid response" do
    check all reads <- reads(), data <- binary(max_length: 80) do
      writes = for {group, offset, size} <- reads, do: {group, offset, :binary.copy(<<0>>, size)}
      items = for {group, offset, size} <- reads, do: {group, offset, size, <<>>}

      for result <- [
            Sum.decode_read(reads, data),
            Sum.decode_write(writes, data),
            Sum.decode_read_write(items, data)
          ] do
        case result do
          {:ok, results} -> assert length(results) == length(reads)
          {:error, {:invalid_response, ^data}} -> :ok
        end
      end
    end
  end

  ## Types and values

  # Of LDATE and LDATE_AND_TIME, the bytes near their ends hold a day or a µs that doesn't fit
  # again: they have a property of their own.
  @scalars [:bool, :byte, :word, :dword, :lword, :sint, :usint, :int, :uint, :dint, :udint, :lint] ++
             [
               :ulint,
               :real,
               :lreal,
               :time,
               :ltime,
               :date,
               :date_and_time,
               :time_of_day,
               :ltime_of_day
             ]

  defp enum do
    gen all base <- member_of([:sint, :int, :udint]),
            names <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 6),
                uniq_fun: &String.downcase/1,
                max_length: 4
              ),
            values <- list_of(integer(0..100), length: length(names)) do
      {:enum, base, Enum.zip(names, values)}
    end
  end

  defp leaf do
    one_of([
      member_of(@scalars),
      map(integer(0..12), &{:string, &1}),
      map(integer(0..12), &{:wstring, &1}),
      map(integer(0..6), &{:raw, &1}),
      enum()
    ])
  end

  defp type(leaf \\ leaf()) do
    tree(leaf, fn child ->
      one_of([
        gen all type <- child,
                dims <-
                  list_of(tuple({integer(-2..2), integer(0..2)}), min_length: 1, max_length: 2) do
          {:array, type, for({first, n} <- dims, do: {first, first + n})}
        end,
        gen all members <- list_of(one_of([child, constant(:bit)]), min_length: 1, max_length: 4),
                pack_mode <- member_of([0, 1, 2, 4, 8]) do
          Type.layout(Enum.with_index(members, fn type, i -> {"m#{i}", type} end),
            pack_mode: pack_mode
          )
        end
      ])
    end)
  end

  defp union(member) do
    gen all types <- list_of(member, min_length: 1, max_length: 3) do
      size = types |> Enum.map(&Type.size/1) |> Enum.max()
      {:union, size, Enum.with_index(types, fn type, i -> {"u#{i}", 0, type} end)}
    end
  end

  property "a value decoded from any bytes encodes to bytes that decode to it again" do
    check all type <- scale(type(), &min(&1, 20)), bytes <- binary(length: Type.size(type)) do
      assert {:ok, value} = Type.decode(type, bytes)
      assert Type.decode(type, Type.encode(type, value)) == {:ok, value}
    end
  end

  property "any bytes decode to a value, as many as the type takes, or else to an error" do
    utf8 = map(integer(0..12), &{:string, &1, :utf8})
    leaf = one_of([leaf(), utf8, union(leaf()), member_of([:ldate, :ldate_and_time])])

    check all type <- scale(type(leaf), &min(&1, 20)),
              size = Type.size(type),
              bytes <- one_of([binary(length: size), binary(max_length: size + 2)]) do
      if byte_size(bytes) == size,
        do: assert({:ok, _value} = Type.decode(type, bytes)),
        else: assert(Type.decode(type, bytes) == :error)
    end
  end

  property "a UTF-8 STRING holds what fits it" do
    check all string <- string(:printable, max_length: 10),
              spare <- integer(0..3),
              n = byte_size(string) + spare do
      assert Type.decode({:string, n, :utf8}, Type.encode({:string, n, :utf8}, string)) ==
               {:ok, string}
    end
  end

  property "LDATE and LDATE_AND_TIME hold the dates and times 64 bits of ns do" do
    check all days <- integer(-106_000..106_000),
              us <- integer(-9_000_000_000_000_000..9_000_000_000_000_000) do
      date = Date.add(~D[1970-01-01], days)
      datetime = NaiveDateTime.add(~N[1970-01-01 00:00:00.000000], us, :microsecond)
      assert Type.decode(:ldate, Type.encode(:ldate, date)) == {:ok, date}

      assert Type.decode(:ldate_and_time, Type.encode(:ldate_and_time, datetime)) ==
               {:ok, datetime}
    end
  end

  property "any type name parses to a type or an error" do
    token =
      member_of(
        [
          "ARRAY",
          " [",
          "[",
          "]",
          "..",
          ",",
          " OF ",
          "STRING",
          "WSTRING",
          "(",
          ")",
          "INT",
          "-1",
          "0",
          "10"
        ] ++
          [
            " ",
            "POINTER TO ",
            "REFERENCE TO ",
            "XINT",
            "99999999999999999999",
            "ß",
            "ﬀ",
            "ɐ",
            "é",
            "BOOL"
          ]
      )

    check all name <- one_of([string(:printable), map(list_of(token), &Enum.join/1)]),
              size <- one_of([constant(nil), integer(0..16)]) do
      case Type.parse(name, size) do
        {:ok, type} -> assert Type.check!(type) == type
        :error -> :ok
      end
    end
  end

  ## Symbols and data types, as a device describes them

  defp entry_strings do
    name = one_of([string(:alphanumeric, max_length: 8), binary(max_length: 8)])

    type =
      one_of([
        member_of([
          "",
          "INT",
          "LREAL",
          "STRING(10)",
          "WSTRING(3)",
          "ARRAY [0..1] OF INT",
          "BOOL",
          "ST_X"
        ]),
        binary(max_length: 8)
      ])

    tuple({name, type, binary(max_length: 4)})
  end

  defp symbol_entry do
    gen all numbers <- binary(length: 12),
            data_type <- one_of([member_of([0, 2, 3, 5, 17, 30, 31, 33, 65]), u32()]),
            flags <- integer(0..0xFFFF),
            {name, type, comment} <- entry_strings(),
            extra <- binary(max_length: 32) do
      body =
        <<numbers::binary, data_type::32-little, flags::32-little, byte_size(name)::16-little,
          byte_size(type)::16-little, byte_size(comment)::16-little, name::binary, 0,
          type::binary, 0, comment::binary, 0, extra::binary>>

      <<byte_size(body) + 4::32-little, body::binary>>
    end
  end

  defp data_type_entry do
    tree(data_type_entry(constant([])), &data_type_entry(list_of(&1, max_length: 3)))
  end

  defp data_type_entry(members) do
    gen all numbers <- binary(length: 12),
            size <- integer(0..32),
            offset <- integer(0..32),
            data_type <- member_of([0, 2, 3, 4, 5, 16, 17, 18, 19, 20, 21, 30, 31, 33, 65, 99]),
            flags <- integer(0..0xFFFF),
            {name, type, comment} <- entry_strings(),
            dims <- list_of(tuple({integer(-3..3), integer(0..4)}), max_length: 2),
            members <- members,
            extra <- binary(max_length: 32) do
      body =
        <<numbers::binary, size::32-little, offset::32-little, data_type::32-little,
          flags::32-little, byte_size(name)::16-little, byte_size(type)::16-little,
          byte_size(comment)::16-little, length(dims)::16-little, length(members)::16-little,
          name::binary, 0, type::binary, 0, comment::binary, 0>>

      body = for({first, n} <- dims, into: body, do: <<first::signed-32-little, n::32-little>>)
      body = IO.iodata_to_binary([body, members, extra])
      <<byte_size(body) + 4::32-little, body::binary>>
    end
  end

  property "any symbol entries decode to symbols or an error" do
    entry = one_of([symbol_entry(), map(symbol_entry(), &corrupt/1), binary(max_length: 40)])

    check all entries <- list_of(entry, max_length: 4) do
      bytes = IO.iodata_to_binary(entries)

      for result <- [Symbol.decode(bytes), Symbol.decode_all(bytes)] do
        case result do
          {:ok, %Symbol{} = symbol} -> assert is_list(Symbol.flags(symbol))
          {:ok, symbols} -> assert Enum.all?(symbols, &match?(%Symbol{}, &1))
          :error -> :ok
        end
      end
    end
  end

  property "any data type entries decode to data types or an error, and those to a type" do
    entry =
      one_of([data_type_entry(), map(data_type_entry(), &corrupt/1), binary(max_length: 60)])

    check all entries <- list_of(entry, max_length: 3),
              resolved <- one_of([constant(:error), map(leaf(), &{:ok, &1})]) do
      bytes = IO.iodata_to_binary(entries)

      for result <- [DataType.decode(bytes), DataType.decode_all(bytes)],
          data_type <- found(result) do
        type = DataType.to_type(data_type, fn _name, _size -> resolved end)
        assert Type.check!(type) == type
        size = Type.size(type)

        if size <= 4096,
          do: assert({:ok, _value} = Type.decode(type, :binary.copy(<<0xA5>>, size)))
      end
    end
  end

  defp found({:ok, %DataType{} = data_type}), do: [data_type]
  defp found({:ok, data_types}), do: data_types
  defp found(:error), do: []

  ## Discovery

  defp datagram do
    gen all service <- u32(),
            invoke_id <- u32(),
            net_id <- binary(length: 6),
            port <- integer(0..65535),
            tags <- list_of(tuple({integer(0..65535), binary(max_length: 40)}), max_length: 6) do
      %{service: service, invoke_id: invoke_id, net_id: net_id, port: port, tags: tags}
    end
  end

  property "a discovery datagram decodes to itself, and is never empty" do
    check all datagram <- datagram() do
      bytes = Discovery.encode(datagram)
      assert byte_size(bytes) >= 24
      assert Discovery.decode(bytes) == {:ok, datagram}
    end
  end

  property "any bytes are a discovery datagram or an error" do
    corrupted = map(datagram(), &corrupt(Discovery.encode(&1)))

    check all bytes <- one_of([binary(max_length: 200), corrupted]) do
      case Discovery.decode(bytes) do
        {:ok, %{net_id: <<_::48>>, tags: tags}} ->
          assert Enum.all?(
                   tags,
                   &match?({id, value} when id in 0..65535 and is_binary(value), &1)
                 )

        :error ->
          :ok
      end
    end
  end

  ## Secure ADS, NetIds, return codes

  property "a TlsConnectInfo decodes to itself" do
    ascii = string(:alphanumeric, max_length: 20)

    check all flags <-
                map(
                  list_of(
                    member_of([
                      :response,
                      :ams_allowed,
                      :server_info,
                      :own_file,
                      :self_signed,
                      :ip_address,
                      :ignore_cn,
                      :add_remote
                    ])
                  ),
                  &Enum.uniq/1
                ),
              net_id <- binary(length: 6),
              hostname <- ascii,
              credentials <- one_of([constant(nil), tuple({ascii, ascii})]),
              rest <- binary(max_length: 8) do
      bytes = Secure.connect_info(flags, net_id, hostname, credentials)
      assert {:ok, info, ^rest} = Secure.decode_connect_info(bytes <> rest)
      assert Enum.sort(info.flags) == Enum.sort(flags)
      assert %{net_id: ^net_id, hostname: ^hostname, error: nil} = info
      assert info.credentials == if(credentials == {"", ""}, do: nil, else: credentials)
    end
  end

  property "any bytes are a TlsConnectInfo, the start of one, or an error" do
    connect_info =
      map(
        binary(length: 6),
        &Secure.connect_info([:self_signed], &1, "host", {"user", "password"})
      )

    check all bytes <- one_of([binary(max_length: 600), map(connect_info, &corrupt/1)]) do
      case Secure.decode_connect_info(bytes) do
        {:ok, %{flags: flags, hostname: hostname}, rest} ->
          assert is_list(flags) and String.valid?(hostname) and String.ends_with?(bytes, rest)

        result ->
          assert result in [:more, :error]
      end
    end
  end

  property "a NetId parses from what it prints, and anything else is an error" do
    check all net_id <- binary(length: 6), text <- string(:printable) do
      assert NetId.parse(NetId.to_string(net_id)) == {:ok, net_id}

      case NetId.parse(text) do
        {:ok, <<_::48>>} -> :ok
        :error -> :ok
      end
    end
  end

  property "any return code has a name, or is its number" do
    check all code <- one_of([integer(0..0x2000), u32()]) do
      name = ReturnCode.name(code)
      assert is_atom(name) or is_integer(name)
      if is_atom(name), do: assert(ReturnCode.name(ReturnCode.code(name)) == name)
    end
  end
end
