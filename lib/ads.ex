defmodule ADS do
  @moduledoc """
  ADS, Beckhoff's Automation Device Specification, in pure Elixir, as a client: reading, writing
  and watching the variables of a TwinCAT PLC by name, over TCP or over Secure ADS (TLS).

    * `ADS.Client` talks to a PLC, or any other ADS device, over one connection, with many requests
      on the way at once, and reconnects by itself.
    * `ADS.Discovery` finds PLCs on the network, and adds and deletes routes on them, over UDP;
      `ADS.Client.routes/2` lists them, and `mix ads.route` does all three from the command line.
    * `ADS.Type` turns PLC values into Elixir terms and back, from the types the PLC describes or
      ones given by hand.
    * `ADS.Symbol` and `ADS.DataType` are the PLC's own descriptions of its variables and types.
    * `ADS.AMS`, `ADS.Command` and `ADS.Sum` encode and decode, for those who bring their own
      transport; `ADS.Secure` and `ADS.Certificate` are for Secure ADS.

  ## Addresses

  An ADS device is reached by the AMS NetId of the system it runs on, six numbers such as
  `"5.36.69.176.1.1"`, and its AMS port on that system:

  | Port | Device |
  |---|---|
  | 851, 852, ... | the PLC runtimes of TwinCAT 3 |
  | 801, 811, ... | the PLC runtimes of TwinCAT 2 |
  | 10000 | the system service |
  | 300 | I/O |
  | 500 | NC |

  A NetId has nothing to do with an IP address, though it's often made from one by adding `.1.1`.
  Inside a device, data is addressed by an index group and an index offset, both 32 bits, or by
  the name of a variable, such as `"MAIN.nCounter"`.

  ## States

  A device is in one of the ADS states, an atom here: `:invalid`, `:idle`, `:reset`, `:init`,
  `:start`, `:run`, `:stop`, `:save_config`, `:load_config`, `:power_failure`, `:power_good`,
  `:error`, `:shutdown`, `:suspend`, `:resume`, `:config` and `:reconfig`; or the number of a state
  that has no name.

  ## Errors

    * `{:error, name}`: the device or a router answered with an ADS return code, such as
      `:device_symbol_not_found` (see `ADS.ReturnCode`), or its number if it has no name
    * `{:error, :timeout}`: no answer in time
    * `{:error, :closed}`: there's no connection, or it was lost before the answer came
    * `{:error, {:invalid_response, data}}`: the answer doesn't fit the request

  A request that doesn't fit the protocol, or a value that doesn't fit its type, raises
  `ArgumentError` in the caller and is never sent.
  """

  @typedoc "An AMS NetId, such as `\"5.36.69.176.1.1\"`."
  @type net_id :: String.t()

  @typedoc "An AMS port, such as 851 for the first PLC runtime of TwinCAT 3."
  @type ams_port :: 0..65535

  @type index_group :: 0..0xFFFFFFFF
  @type index_offset :: 0..0xFFFFFFFF

  @type state ::
          :invalid
          | :idle
          | :reset
          | :init
          | :start
          | :run
          | :stop
          | :save_config
          | :load_config
          | :power_failure
          | :power_good
          | :error
          | :shutdown
          | :suspend
          | :resume
          | :config
          | :reconfig
          | 0..65535

  @type error ::
          ADS.ReturnCode.name()
          | non_neg_integer
          | :timeout
          | :closed
          | {:invalid_response, binary}

  @states ~w(invalid idle reset init start run stop save_config load_config power_failure
             power_good error shutdown suspend resume config reconfig)a
          |> Enum.with_index()
          |> Map.new(fn {name, code} -> {code, name} end)
  @state_codes Map.new(@states, fn {code, name} -> {name, code} end)

  @doc """
  The name of an ADS state, or its number if it has none.

      iex> ADS.state_name(5)
      :run
      iex> ADS.state_name(99)
      99
  """
  @spec state_name(0..65535) :: state
  def state_name(code) when code in 0..65535, do: Map.get(@states, code, code)

  @doc """
  The number of an ADS state, given by name or number.

      iex> ADS.state_code(:stop)
      6
  """
  @spec state_code(state) :: 0..65535
  def state_code(code) when code in 0..65535, do: code

  def state_code(name) do
    case @state_codes do
      %{^name => code} -> code
      _ -> raise ArgumentError, "not an ADS state: #{inspect(name)}"
    end
  end
end
