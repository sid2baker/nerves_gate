defmodule NervesGate do
  @moduledoc """
  Public API for the gateway. Start here; callers do not need Jido or runtime APIs.

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

  Status reads the two domains independently; it is not an atomic snapshot or
  cached state. Subscriptions belong to the caller. Property notifications are
  hints to read again; subscribe before reading and after reconnecting.

  Commands return `:ok`, `{:ok, value}` or `{:error, %{code: code, message: message}}`.
  They do not bundle a status read. On an unknown outcome, read before retrying:
  caller timeout does not cancel admitted work.

  Options:

    * `:access` — trusted server-observed USB access for `network_propose/2` only.
      Never populate it from user parameters or forwarded headers.
    * `:network`, `:remote` — domain servers for tests or independent instances.
      No client object or extra process is required.
  """
  alias NervesGate.{Error, Network, Remote, Status}

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
      invoke(fn -> Network.propose(settings, network(opts), opts[:access]) end) |> result()
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

  @doc "Request Tailscale connection/enrollment under this hostname. Returns acceptance."
  @spec remote_connect(String.t(), keyword()) :: command_result()
  def remote_connect(hostname, opts \\ []),
    do: remote_command(:connect, %{"hostname" => hostname}, opts)

  @doc "Request a Tailscale hostname change without replacing other daemon preferences."
  @spec remote_configure(String.t(), keyword()) :: command_result()
  def remote_configure(hostname, opts \\ []),
    do: remote_command(:configure, %{"hostname" => hostname}, opts)

  @doc "Request Tailscale sign-out. May interrupt callers using that VPN."
  @spec remote_disconnect(keyword()) :: command_result()
  def remote_disconnect(opts \\ []), do: remote_command(:disconnect, %{}, opts)

  @doc "Read the private HTTPS enrollment URL, or nil. Do not log or broadcast it."
  @spec remote_login_url(keyword()) :: result(String.t() | nil)
  def remote_login_url(opts \\ []) do
    case invoke(fn -> Remote.login_url(remote(opts)) end) do
      {:error, _} -> {:error, Error.new("remote_unavailable", "Tailscale is unavailable.")}
      url -> {:ok, url}
    end
  end

  @doc "Read current network/Tailscale status, capabilities and action availability."
  @spec status(keyword()) :: map()
  def status(opts \\ []),
    do: Status.build(network_status(network(opts)), remote_status(remote(opts)))

  @doc "Subscribe the calling process to domain observations; read status afterward."
  @spec subscribe(keyword()) :: command_result()
  def subscribe(opts \\ []) do
    with :ok <- observe(Network, network(opts)), do: observe(Remote, remote(opts))
  end

  def target, do: Application.fetch_env!(:nerves_gate, :target)
  def version, do: Application.spec(:nerves_gate, :vsn) |> to_string()

  defp remote_command(operation, params, opts) do
    invoke(fn -> Remote.command(operation, params, remote(opts)) end) |> result()
  end

  defp network(opts), do: Keyword.get(opts, :network, Network)
  defp remote(opts), do: Keyword.get(opts, :remote, Remote)

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
