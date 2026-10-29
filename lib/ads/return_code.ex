defmodule ADS.ReturnCode do
  @moduledoc """
  The return codes of ADS, which a device or a router answers with when something goes wrong.

  Each has a name, Beckhoff's identifier in snake case with its words spelled out, and the prefix
  of its group kept: `ERR_TARGETPORTNOTFOUND` is `:target_port_not_found`,
  `ROUTERERR_MAILBOXFULL` is `:router_mailbox_full`, `ADSERR_DEVICE_SYMBOLNOTFOUND` is
  `:device_symbol_not_found`, `ADSERR_CLIENT_SYNCTIMEOUT` is `:client_sync_timeout` and
  `RTERR_INTERNAL` is `:rt_internal`.

  | Codes | Group |
  |---|---|
  | `0x0` to `0x1E` | the AMS router and transport |
  | `0x500` to `0x50D` | the router's resources |
  | `0x700` to `0x739` | the device: `:device_...` |
  | `0x740` to `0x756` | Beckhoff's client libraries: `:client_...` |
  | `0x1000` to `0x101A` | the real-time system: `:rt_...` |

  Windows and .NET show them as HRESULTs, `0x9811_0000` plus the code, which `name/1` takes too.

      iex> ADS.ReturnCode.name(0x710)
      :device_symbol_not_found
      iex> ADS.ReturnCode.name(0x9811_0006)
      :target_port_not_found
      iex> ADS.ReturnCode.name(0x799)
      1945
      iex> ADS.ReturnCode.code(:device_symbol_version_invalid)
      0x711
  """

  @names %{
    0x0 => :no_error,
    0x1 => :internal,
    0x2 => :no_rtime,
    0x3 => :alloc_locked_memory,
    0x4 => :insert_mailbox,
    0x5 => :wrong_receive_hmsg,
    0x6 => :target_port_not_found,
    0x7 => :target_machine_not_found,
    0x8 => :unknown_command_id,
    0x9 => :bad_task_id,
    0xA => :no_io,
    0xB => :unknown_ams_command,
    0xC => :win32_error,
    0xD => :port_not_connected,
    0xE => :invalid_ams_length,
    0xF => :invalid_ams_net_id,
    0x10 => :low_installation_level,
    0x11 => :no_debug_interrupt_available,
    0x12 => :port_disabled,
    0x13 => :port_already_connected,
    0x14 => :ams_sync_win32_error,
    0x15 => :ams_sync_timeout,
    0x16 => :ams_sync_ams_error,
    0x17 => :ams_sync_no_index_in_map,
    0x18 => :invalid_ams_port,
    0x19 => :no_memory,
    0x1A => :tcp_send,
    0x1B => :host_unreachable,
    0x1C => :invalid_ams_fragment,
    0x1D => :tls_send,
    0x1E => :access_denied,
    0x500 => :router_no_locked_memory,
    0x501 => :router_resize_memory,
    0x502 => :router_mailbox_full,
    0x503 => :router_debug_mailbox_full,
    0x504 => :router_unknown_port_type,
    0x505 => :router_not_initialized,
    0x506 => :router_port_already_in_use,
    0x507 => :router_not_registered,
    0x508 => :router_no_more_queues,
    0x509 => :router_invalid_port,
    0x50A => :router_not_activated,
    0x50B => :router_fragment_mailbox_full,
    0x50C => :router_fragment_timeout,
    0x50D => :router_to_be_removed,
    0x700 => :device_error,
    0x701 => :device_service_not_supported,
    0x702 => :device_invalid_group,
    0x703 => :device_invalid_offset,
    0x704 => :device_invalid_access,
    0x705 => :device_invalid_size,
    0x706 => :device_invalid_data,
    0x707 => :device_not_ready,
    0x708 => :device_busy,
    0x709 => :device_invalid_context,
    0x70A => :device_no_memory,
    0x70B => :device_invalid_parameter,
    0x70C => :device_not_found,
    0x70D => :device_syntax,
    0x70E => :device_incompatible,
    0x70F => :device_exists,
    0x710 => :device_symbol_not_found,
    0x711 => :device_symbol_version_invalid,
    0x712 => :device_invalid_state,
    0x713 => :device_trans_mode_not_supported,
    0x714 => :device_notify_handle_invalid,
    0x715 => :device_client_unknown,
    0x716 => :device_no_more_handles,
    0x717 => :device_invalid_watch_size,
    0x718 => :device_not_initialized,
    0x719 => :device_timeout,
    0x71A => :device_no_interface,
    0x71B => :device_invalid_interface,
    0x71C => :device_invalid_class_id,
    0x71D => :device_invalid_object_id,
    0x71E => :device_pending,
    0x71F => :device_aborted,
    0x720 => :device_warning,
    0x721 => :device_invalid_array_index,
    0x722 => :device_symbol_not_active,
    0x723 => :device_access_denied,
    0x724 => :device_license_not_found,
    0x725 => :device_license_expired,
    0x726 => :device_license_exceeded,
    0x727 => :device_license_invalid,
    0x728 => :device_license_system_id,
    0x729 => :device_license_no_time_limit,
    0x72A => :device_license_future_issue,
    0x72B => :device_license_time_too_long,
    0x72C => :device_exception,
    0x72D => :device_license_duplicated,
    0x72E => :device_signature_invalid,
    0x72F => :device_certificate_invalid,
    0x730 => :device_license_oem_not_found,
    0x731 => :device_license_restricted,
    0x732 => :device_license_demo_denied,
    0x733 => :device_invalid_function_id,
    0x734 => :device_out_of_range,
    0x735 => :device_invalid_alignment,
    0x736 => :device_license_platform,
    0x737 => :device_forward_passive_level,
    0x738 => :device_forward_dispatch_level,
    0x739 => :device_forward_real_time,
    0x740 => :client_error,
    0x741 => :client_invalid_parameter,
    0x742 => :client_list_empty,
    0x743 => :client_variable_used,
    0x744 => :client_duplicate_invoke_id,
    0x745 => :client_sync_timeout,
    0x746 => :client_win32_error,
    0x747 => :client_timeout_invalid,
    0x748 => :client_port_not_open,
    0x749 => :client_no_ams_address,
    0x750 => :client_sync_internal,
    0x751 => :client_add_hash,
    0x752 => :client_remove_hash,
    0x753 => :client_no_more_symbols,
    0x754 => :client_sync_response_invalid,
    0x755 => :client_sync_port_locked,
    0x756 => :client_request_cancelled,
    0x1000 => :rt_internal,
    0x1001 => :rt_bad_timer_periods,
    0x1002 => :rt_invalid_task_pointer,
    0x1003 => :rt_invalid_stack_pointer,
    0x1004 => :rt_priority_exists,
    0x1005 => :rt_no_more_tcb,
    0x1006 => :rt_no_more_semaphores,
    0x1007 => :rt_no_more_queues,
    0x100D => :rt_external_irq_already_defined,
    0x100E => :rt_external_irq_not_defined,
    0x100F => :rt_external_irq_install_failed,
    0x1010 => :rt_irql_not_less_or_equal,
    0x1017 => :rt_vmx_not_supported,
    0x1018 => :rt_vmx_disabled,
    0x1019 => :rt_vmx_controls_missing,
    0x101A => :rt_vmx_enable_fails
  }
  @codes Map.new(@names, fn {code, name} -> {name, code} end)

  @typedoc "The name of a return code, an atom; see the table of `ADS.ReturnCode`."
  @type name :: atom

  @doc "The name of a return code, or the code itself if it has none."
  @spec name(non_neg_integer) :: name | non_neg_integer
  def name(code) when code in 0x9811_0000..0x9811_FFFF, do: name(code - 0x9811_0000)
  def name(code) when is_integer(code) and code >= 0, do: Map.get(@names, code, code)

  @doc "The number of a return code, given by name or number."
  @spec code(name | non_neg_integer) :: non_neg_integer
  def code(code) when is_integer(code) and code >= 0, do: code

  def code(name) do
    case @codes do
      %{^name => code} -> code
      _ -> raise ArgumentError, "not an ADS return code: #{inspect(name)}"
    end
  end

  @doc "All return codes and their names."
  @spec all() :: %{non_neg_integer => name}
  def all, do: @names
end
