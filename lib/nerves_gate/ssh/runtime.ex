defmodule NervesGate.SSH.Runtime do
  @moduledoc "Idempotent NervesSSH listener operations for `NervesGate.SSH`."

  alias NervesGate.Storage
  alias NervesGate.Tailnet.Address
  alias NervesSSH.Options

  @port 22

  @spec address(map()) :: :inet.ip4_address() | nil
  def address(%{online: true, ipv4: ipv4}) when is_binary(ipv4) do
    case Address.parse_ipv4(ipv4) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  def address(_tailnet), do: nil

  @spec listener_valid?(map() | nil, :inet.ip4_address()) :: boolean()
  def listener_valid?(%{pid: pid, address: address}, address),
    do: is_pid(pid) and Process.alive?(pid)

  def listener_valid?(_listener, _address), do: false

  @spec observe(:inet.ip4_address() | nil) :: map() | nil
  def observe(nil), do: nil

  def observe(address) do
    NervesGate.SSH.DynamicSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {NervesGate.SSH.Daemon, pid, _type, _modules} when is_pid(pid) ->
        %{pid: pid, address: address}

      _other ->
        nil
    end)
  catch
    :exit, _reason -> nil
  end

  @spec start(:inet.ip4_address()) :: {:ok, pid()} | {:error, term()}
  def start(address) do
    if Address.ipv4?(address) do
      options = options(address)

      child_spec = %{
        id: NervesGate.SSH.Daemon,
        start: {NervesSSH, :start_link, [options]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(NervesGate.SSH.DynamicSupervisor, child_spec) do
        {:ok, pid} -> verify_start(pid, options.name)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_tailnet_address}
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(NervesGate.SSH.DynamicSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def stop(_pid), do: :ok

  @spec port() :: 22
  def port, do: @port

  defp verify_start(pid, name) do
    case daemon_info(name) do
      {:ok, _info} ->
        {:ok, pid}

      {:error, reason} ->
        stop(pid)
        {:error, reason}
    end
  end

  defp daemon_info(name) do
    NervesSSH.info(name)
  catch
    :exit, reason -> {:error, {:daemon_start_failed, reason}}
  end

  defp options(address) do
    Options.new(
      name: NervesGate.SSH.Daemon,
      authorized_keys: [],
      user_passwords: [],
      port: @port,
      subsystems: [],
      system_dir: Storage.path("nerves_ssh"),
      user_dir: Path.join(System.tmp_dir!(), "nerves_gate_ssh"),
      shell: :elixir,
      exec: :disabled,
      daemon_option_overrides: [inet: :inet, ip: address, no_auth_needed: true]
    )
    |> Options.sanitize()
  end
end
