defmodule NervesGate do
  @moduledoc """
  Public commands and status queries for the gateway. No client process is needed.

  ## Network

      {:ok, settings} = NervesGate.network_validate(settings)
      {:ok, trial_id} = NervesGate.network_propose(settings)
      :ok = NervesGate.network_confirm(trial_id)
      # Or: NervesGate.network_cancel(trial_id)

  Proposals acknowledge temporary application, not persistence.
  Unconfirmed changes roll back after 60 seconds. Only first setup through
  server-verified USB may auto-save, within its independent 15-second bound.

  ## Tailscale

      :ok = NervesGate.remote_connect("gateway")
      {:ok, url} = NervesGate.remote_login_url()
      :ok = NervesGate.remote_configure("new-name")
      :ok = NervesGate.remote_disconnect()

  Remote writes acknowledge acceptance, not daemon completion. Read `status/1`
  for progress. Login URLs are private and never included in status.

  ## Reading and observing

      :ok = NervesGate.subscribe()
      status = NervesGate.status()

  Status reads the domains independently; it is not an atomic snapshot or
  cached state. Subscriptions belong to the caller. Property notifications are
  hints to read again; subscribe before reading and after reconnecting.

  Commands return `:ok`, `{:ok, value}` or `{:error, %{code: code, message: message}}`.
  They do not bundle a status read. On an unknown outcome, read before retrying:
  caller timeout does not cancel admitted work.

  Options:

    * `:access` — trusted server-observed USB access for `network_propose/2` only.
      Never populate it from user parameters or forwarded headers.
    * `:expected` — the state an editor's draft started from: saved network settings
      for `network_propose/2`, or the Tailscale hostname for `remote_connect/2` and
      `remote_configure/2`. The owning process rejects a stale draft before any change.
    * `:network`, `:remote`, `:equipment`, `:indicators`, `:buses` — domain servers for tests or independent instances.
      No client object or extra process is required.
  """
  alias NervesGate.{Buses, Equipment, Error, Indicators, Network, Remote, Status}

  @type error :: %{code: String.t(), message: String.t()}
  @type result(value) :: {:ok, value} | {:error, error()}
  @type command_result :: :ok | {:error, error()}

  @doc "Validate and normalize network settings without a running gateway or any effects."
  @spec network_validate(map()) :: result(map())
  def network_validate(settings), do: Network.validate(settings) |> result()

  @doc "Apply a protected trial. Returns its ID; use that exact ID to confirm or cancel."
  @spec network_propose(map(), keyword()) :: result(String.t())
  def network_propose(settings, opts \\ []) do
    with {:ok, settings} <- network_validate(settings) do
      invoke(fn ->
        Network.propose(
          settings,
          network(opts),
          opts[:access],
          Keyword.get(opts, :expected, :any)
        )
      end)
      |> result()
    end
  end

  @doc "Persist an applied trial after checking its ID, deadline and current readiness."
  @spec network_confirm(String.t(), keyword()) :: command_result()
  def network_confirm(trial_id, opts \\ []) do
    with :ok <- trial_id(trial_id) do
      invoke(fn -> Network.confirm(trial_id, network(opts)) end) |> result()
    end
  end

  @doc "Restore the saved network settings for the matching trial."
  @spec network_cancel(String.t(), keyword()) :: command_result()
  def network_cancel(trial_id, opts \\ []) do
    with :ok <- trial_id(trial_id) do
      invoke(fn -> Network.cancel(trial_id, network(opts)) end) |> result()
    end
  end

  @doc "Request Tailscale connection/enrollment; optional `auth_key:` is used once, never saved. Returns acceptance."
  @spec remote_connect(String.t(), keyword()) :: command_result()
  def remote_connect(hostname, opts \\ []),
    do:
      invoke(fn ->
        Remote.connect(hostname, remote(opts), Keyword.take(opts, [:auth_key, :expected]))
      end)
      |> result()

  @doc "Request a Tailscale hostname change without replacing other daemon preferences."
  @spec remote_configure(String.t(), keyword()) :: command_result()
  def remote_configure(hostname, opts \\ []),
    do:
      invoke(fn -> Remote.configure(hostname, remote(opts), Keyword.take(opts, [:expected])) end)
      |> result()

  @doc "Request Tailscale down without signing out. May interrupt callers using that VPN."
  @spec remote_disconnect(keyword()) :: command_result()
  def remote_disconnect(opts \\ []),
    do: invoke(fn -> Remote.disconnect(remote(opts)) end) |> result()

  @doc "Read the private HTTPS enrollment URL, or nil. Do not log or broadcast it."
  @spec remote_login_url(keyword()) :: result(String.t() | nil)
  def remote_login_url(opts \\ []) do
    case invoke(fn -> Remote.login_url(remote(opts)) end) do
      {:error, _} -> {:error, Error.new("remote_unavailable", "Tailscale is unavailable.")}
      url -> {:ok, url}
    end
  end

  @doc "Validate and persist one OpenSSH public key before allowing new SSH logins."
  @spec ssh_add_key(String.t()) :: command_result()
  def ssh_add_key(key), do: invoke(fn -> NervesGate.SSH.add_key(key) end) |> result()

  @doc "Persist removal by fingerprint from status.ssh.keys. Existing sessions remain open."
  @spec ssh_remove_key(String.t()) :: command_result()
  def ssh_remove_key(fingerprint),
    do: invoke(fn -> NervesGate.SSH.remove_key(fingerprint) end) |> result()

  @doc "Identify with all three LEDs for five seconds, then resume current status patterns."
  @spec identify(keyword()) :: command_result()
  def identify(opts \\ []),
    do: invoke(fn -> Indicators.identify(indicators(opts)) end) |> result()

  @doc "Configure an allowlisted bus port. CAN applies to the kernel; RS485 opt-in resets on restart."
  def bus_configure(port, params, opts \\ []),
    do: invoke(fn -> Buses.configure(port, params, buses(opts)) end) |> result()

  @doc "Start a receive-only capture: at most five seconds, 200 CAN frames or 4096 serial bytes."
  def bus_capture(port, opts \\ []),
    do: invoke(fn -> Buses.capture(port, buses(opts)) end) |> result()

  @doc "Send one explicitly authorized Modbus RTU read (function 3/4), with no retry or scan."
  def modbus_read(port, params, opts \\ []),
    do: invoke(fn -> Buses.modbus_read(port, params, buses(opts)) end) |> result()

  @doc "Read domain status, capabilities and action availability."
  @spec status(keyword()) :: map()
  def status(opts \\ []),
    do:
      Status.build(
        network_status(network(opts)),
        remote_status(remote(opts)),
        equipment_status(equipment(opts)),
        indicators_status(indicators(opts)),
        buses_status(buses(opts)),
        status_input(:ssh),
        status_input(:system)
      )

  # Sanitized inputs shared by direct status queries and the device read model.
  @doc false
  def status_input(:network), do: network_status(Network)
  def status_input(:remote), do: remote_status(Remote)
  def status_input(:equipment), do: equipment_status(Equipment)
  def status_input(:indicators), do: indicators_status(Indicators)
  def status_input(:buses), do: buses_status(Buses)

  def status_input(:ssh) do
    case invoke(fn -> NervesGate.SSH.status() end) do
      {:error, _} -> NervesGate.SSH.unavailable()
      status -> status
    end
  end

  def status_input(:system) do
    %{
      firmware: version(),
      target: to_string(target()),
      node: Node.self(),
      elixir: System.version(),
      otp: System.otp_release()
    }
  end

  @doc "Subscribe the calling process to domain observations; read status afterward."
  @spec subscribe(keyword()) :: command_result()
  def subscribe(opts \\ []) do
    with :ok <- observe(Network, network(opts)),
         :ok <- observe(Remote, remote(opts)),
         :ok <- observe(Equipment, equipment(opts)),
         :ok <- observe(Indicators, indicators(opts)),
         :ok <- observe(Buses, buses(opts)),
         do: NervesGate.SSH.observe()
  end

  @doc "Run one explicit ARP-only scan of the confirmed equipment subnet (at most /24 and five seconds)."
  @spec equipment_scan(keyword()) :: command_result()
  def equipment_scan(opts \\ []) do
    invoke(fn -> Network.scan(equipment(opts), network(opts)) end) |> result()
  end

  @doc "Save a local equipment label. IDs come from status; an empty label removes it."
  @spec equipment_label(String.t(), String.t(), keyword()) :: command_result()
  def equipment_label(id, label, opts \\ []) do
    invoke(fn -> Equipment.label(id, label, equipment(opts)) end) |> result()
  end

  @doc "Advertise the confirmed dedicated equipment IPv4 subnet. Returns after local readback."
  @spec equipment_share(keyword()) :: command_result()
  def equipment_share(opts \\ []) do
    invoke(fn -> Network.sharing(:sharing_enable, %{}, network(opts)) end) |> result()
  end

  @doc "Withdraw the confirmed equipment subnet, preserving other routes and Tailscale preferences."
  @spec equipment_unshare(keyword()) :: command_result()
  def equipment_unshare(opts \\ []) do
    invoke(fn -> Network.sharing(:sharing_disable, %{}, network(opts)) end) |> result()
  end

  @doc "Read the private distribution cookie. Never include it in status, notifications or logs."
  def distribution_cookie, do: {:ok, Node.get_cookie()}

  def target do
    Application.fetch_env!(:nerves_gate, :target)
  end

  def version, do: Application.spec(:nerves_gate, :vsn) |> to_string()

  defp network(opts), do: Keyword.get(opts, :network, Network)
  defp remote(opts), do: Keyword.get(opts, :remote, Remote)
  defp equipment(opts), do: Keyword.get(opts, :equipment, Equipment)
  defp indicators(opts), do: Keyword.get(opts, :indicators, Indicators)
  defp buses(opts), do: Keyword.get(opts, :buses, Buses)

  defp trial_id(id) when is_binary(id), do: :ok
  defp trial_id(_), do: {:error, Error.new("invalid_parameters", "Supply a trial ID string.")}

  defp result({:error, reason}), do: {:error, Error.from(reason)}
  defp result(value), do: value

  defp observe(_, nil), do: :ok
  defp observe(module, server), do: invoke(fn -> module.observe(server) end) |> result()

  defp remote_status(server) do
    case invoke(fn -> Remote.status(server) end) do
      {:error, _} -> Remote.unavailable()
      status -> status
    end
  end

  defp equipment_status(server) do
    case invoke(fn -> Equipment.status(server) end) do
      {:error, _} -> Equipment.unavailable()
      status -> status
    end
  end

  defp indicators_status(server) do
    case invoke(fn -> Indicators.status(server) end) do
      {:error, _} -> Indicators.unavailable()
      status -> status
    end
  end

  defp buses_status(server) do
    case invoke(fn -> Buses.status(server) end) do
      {:error, _} -> Buses.unavailable()
      status -> status
    end
  end

  defp network_status(server) do
    case invoke(fn -> Network.status(server) end) do
      {:error, _} -> nil
      status -> %{status | error: status.error && Error.from(status.error)}
    end
  end

  # The public API is the process-failure boundary. Do not catch exceptions or
  # throws from application code, and do not hide crashes inside domain workers.
  defp invoke(fun) do
    fun.()
  catch
    :exit, {reason, {GenServer, :call, _}} ->
      {:error, if(reason == :noproc, do: :unavailable, else: :outcome_unknown)}
  end
end
