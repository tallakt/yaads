defmodule ADS.CommandTest do
  use ExUnit.Case, async: true

  alias ADS.Command

  # Each request and response as the tables of the ADS spec lay them out: numbers of 4 bytes, but
  # the versions and states, little-endian.

  test "Read Device Info: no data; the result, the version and a name of 16 bytes" do
    assert Command.encode_request(:read_device_info) == {1, <<>>}
    response = <<0::32, 3, 1, 4026::16-little>> <> "Plc30 App" <> <<0::56>>

    assert Command.decode_response(:read_device_info, response) ==
             {:ok, %{name: "Plc30 App", version: {3, 1, 4026}}}
  end

  test "Read: index group, index offset and length; the result, the length and the data" do
    assert Command.encode_request({:read, 0x4020, 8, 2}) ==
             {2, <<0x20, 0x40, 0, 0, 8, 0, 0, 0, 2, 0, 0, 0>>}

    assert Command.decode_response({:read, 0x4020, 8, 2}, <<0::32, 2::32-little, 7, 0>>) ==
             {:ok, <<7, 0>>}

    # less than asked for is what there is; more is not an answer to the request
    assert Command.decode_response({:read, 0x4020, 8, 2}, <<0::32, 1::32-little, 7>>) ==
             {:ok, <<7>>}

    assert Command.decode_response({:read, 0x4020, 8, 2}, <<0::32, 3::32-little, 1, 2, 3>>) ==
             {:error, {:invalid_response, <<0::32, 3::32-little, 1, 2, 3>>}}

    assert {:error, {:invalid_response, _}} =
             Command.decode_response({:read, 0x4020, 8, 2}, <<0::32, 2::32-little, 7>>)
  end

  test "Write: index group, index offset, length and data; the result" do
    assert Command.encode_request({:write, 0x4020, 8, <<1, 2>>}) ==
             {3, <<0x20, 0x40, 0, 0, 8, 0, 0, 0, 2, 0, 0, 0, 1, 2>>}

    assert Command.decode_response({:write, 0x4020, 8, <<1, 2>>}, <<0::32>>) == :ok

    assert Command.decode_response({:write, 0x4020, 8, <<1, 2>>}, <<0x704::32-little>>) ==
             {:error, :device_invalid_access}
  end

  test "Read State: no data; the result, the ADS state and the device state" do
    assert Command.encode_request(:read_state) == {4, <<>>}

    assert Command.decode_response(:read_state, <<0::32, 5, 0, 1, 0>>) ==
             {:ok, %{ads_state: :run, device_state: 1}}

    assert Command.decode_response(:read_state, <<0::32, 99, 0, 0, 0>>) ==
             {:ok, %{ads_state: 99, device_state: 0}}
  end

  test "Write Control: the ADS state, the device state, a length and data; the result" do
    assert Command.encode_request({:write_control, :stop, 0, <<>>}) ==
             {5, <<6, 0, 0, 0, 0, 0, 0, 0>>}

    assert Command.encode_request({:write_control, 16, 2, <<9>>}) ==
             {5, <<16, 0, 2, 0, 1, 0, 0, 0, 9>>}

    assert Command.decode_response({:write_control, :run, 0, <<>>}, <<0::32>>) == :ok
  end

  test "Add Device Notification: 40 bytes, the last 16 reserved; the result and a handle" do
    request = {:add_notification, 0xF005, 0x101, 4, :on_change, 0, 10_000_000}
    assert {6, data} = Command.encode_request(request)

    assert data ==
             <<0x05, 0xF0, 0, 0, 0x01, 0x01, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x96,
               0x98, 0>> <>
               :binary.copy(<<0>>, 16)

    assert {6, <<_::binary-12, 3, 0, 0, 0, _::binary>>} =
             Command.encode_request({:add_notification, 1, 2, 3, :cyclic, 0, 0})

    assert Command.decode_response(request, <<0::32, 77::32-little>>) == {:ok, 77}

    assert Command.decode_response(request, <<0x713::32-little, 0::32>>) ==
             {:error, :device_trans_mode_not_supported}
  end

  test "Delete Device Notification: the handle; the result" do
    assert Command.encode_request({:delete_notification, 77}) == {7, <<77, 0, 0, 0>>}

    assert Command.decode_response({:delete_notification, 77}, <<0x714::32-little>>) ==
             {:error, :device_notify_handle_invalid}
  end

  test "Read Write: index group, index offset, read length, write length and data; as Read" do
    assert Command.encode_request({:read_write, 0xF003, 0, 4, "MAIN.n\0"}) ==
             {9, <<3, 0xF0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 7, 0, 0, 0>> <> "MAIN.n\0"}

    assert Command.decode_response(
             {:read_write, 0xF003, 0, 4, "MAIN.n\0"},
             <<0::32, 4::32-little, 9::32-little>>
           ) ==
             {:ok, <<9, 0, 0, 0>>}
  end

  test "Device Notification: stamps, each a FILETIME and samples, each a handle, a size and data" do
    time = ~U[2026-10-28 12:00:00.123456Z]

    stream =
      <<0::32, 2::32-little>> <>
        <<Command.to_filetime(time)::64-little, 2::32-little>> <>
        <<7::32-little, 2::32-little, 1, 2>> <>
        <<8::32-little, 0::32>> <>
        <<Command.to_filetime(time)::64-little, 1::32-little, 9::32-little, 1::32-little, 3>>

    assert Command.decode_notification(stream) ==
             {:ok, [{time, [{7, <<1, 2>>}, {8, <<>>}]}, {time, [{9, <<3>>}]}]}

    assert {:ok, stamps} =
             Command.decode_notification(Command.encode_notification([{time, [{7, <<1, 2>>}]}]))

    assert stamps == [{time, [{7, <<1, 2>>}]}]
  end

  test "a FILETIME counts 100 ns intervals since 1601, in UTC; past what DateTime holds it's nil" do
    assert Command.from_filetime(0) == ~U[1601-01-01 00:00:00.000000Z]
    # the last digit of the 100 ns intervals is dropped
    assert Command.from_filetime(116_444_736_000_000_019) == ~U[1970-01-01 00:00:00.000001Z]
    assert Command.from_filetime(0xFFFFFFFFFFFFFFFF) == nil
    assert Command.to_filetime(~U[1970-01-01 00:00:01Z]) == 116_444_736_010_000_000
  end

  test "a notification stream cut short, or with counts the data doesn't hold, is no stream" do
    assert Command.decode_notification(<<1, 2, 3>>) == :error
    assert Command.decode_notification(<<0::32, 1::32-little>>) == :error

    assert Command.decode_notification(
             <<0::32, 1::32-little, 0::64, 1::32-little, 7::32-little, 9::32-little, 1>>
           ) == :error

    assert Command.decode_notification(<<0::32, 0::32>>) == {:ok, []}
  end

  test "any result other than 0 is the error of its return code, whatever follows" do
    assert Command.decode_response({:read, 1, 2, 3}, <<0x710::32-little>>) ==
             {:error, :device_symbol_not_found}

    assert Command.decode_response(:read_device_info, <<0x6::32-little, 0::64>>) ==
             {:error, :target_port_not_found}

    assert Command.decode_response(:read_state, <<0x9999::32-little>>) == {:error, 0x9999}
    assert Command.decode_response(:read_state, <<>>) == {:error, {:invalid_response, <<>>}}
  end

  test "a request that doesn't fit the protocol raises, and isn't sent" do
    for request <- [
          {:read, 0x1_0000_0000, 0, 1},
          {:read, -1, 0, 1},
          {:write, 1, 2, :not_binary},
          {:write_control, :flying, 0, <<>>},
          {:write_control, :run, 70_000, <<>>},
          {:add_notification, 1, 2, 3, :sometimes, 0, 0},
          {:delete_notification, -1},
          {:read_write, 1, 2, 3, nil},
          :read_everything
        ] do
      assert_raise ArgumentError, fn -> Command.encode_request(request) end
    end
  end

  test "return codes and states by name and number" do
    assert ADS.ReturnCode.name(0x745) == :client_sync_timeout
    assert ADS.ReturnCode.name(0x1000) == :rt_internal
    assert ADS.ReturnCode.code(:target_machine_not_found) == 7
    assert_raise ArgumentError, fn -> ADS.ReturnCode.code(:nope) end
    assert map_size(ADS.ReturnCode.all()) == length(Enum.uniq(Map.values(ADS.ReturnCode.all())))
    assert ADS.state_code(:config) == 15
    assert ADS.state_name(16) == :reconfig
    assert_raise ArgumentError, fn -> ADS.state_code(:flying) end
  end
end
