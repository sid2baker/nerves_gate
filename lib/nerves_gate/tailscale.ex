defmodule NervesGate.Tailscale do
  @moduledoc "Only application boundary for tailscale_ex calls."

  alias NervesGate.Identity
  alias NervesGate.Tailnet.Manager

  @server NervesGate.Tailscale.Daemon

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started, do: manager().ensure_started()

  @spec status() :: {:ok, map()} | {:error, atom()}
  def status do
    client = backend()
    daemon_call(fn -> client.status(@server) end, :status_unavailable)
  end

  @spec enroll(String.t()) :: :ok | {:error, atom()}
  def enroll(auth_key) when is_binary(auth_key) and byte_size(auth_key) in 8..512 do
    client = backend()

    with :ok <- ensure_started(),
         result <- daemon_call(fn -> client.login(@server, auth_key) end, :authentication_failed),
         :ok <- successful(result),
         result <-
           daemon_call(
             fn -> client.cli(@server, "set", ["--hostname=#{Identity.get().hostname}"]) end,
             :hostname_failed
           ),
         :ok <- successful(result) do
      :ok
    else
      _failure -> {:error, :authentication_failed}
    end
  end

  def enroll(_auth_key), do: {:error, :authentication_failed}

  @doc "Returns the selected Tailscale account profile used for rollback journaling."
  @spec current_profile_id() :: {:ok, String.t()} | {:error, atom()}
  def current_profile_id do
    with {:ok, profiles} <- profiles(),
         %{"id" => id} when is_binary(id) <- Enum.find(profiles, &Map.get(&1, "selected", false)) do
      {:ok, id}
    else
      _other -> {:error, :tailnet_profile_unavailable}
    end
  end

  @doc "Logs into a temporary account profile and returns rollback metadata."
  @spec stage_enrollment(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()} | {:error, atom(), map()}
  def stage_enrollment(auth_key, change_id, previous_profile_id)
      when is_binary(auth_key) and byte_size(auth_key) in 8..512 and
             is_binary(change_id) and is_binary(previous_profile_id) do
    client = backend()
    nickname = "nervesgate-pending-#{String.slice(change_id, 0, 12)}"

    arguments = [
      "--auth-key",
      auth_key,
      "--hostname=#{Identity.get().hostname}",
      "--nickname=#{nickname}",
      "--accept-dns=false"
    ]

    with :ok <- ensure_started(),
         result <-
           daemon_call(fn -> client.cli(@server, "login", arguments) end, :authentication_failed),
         :ok <- successful(result),
         {:ok, candidate_profile_id} <- current_profile_id() do
      metadata = %{
        "previous_profile_id" => previous_profile_id,
        "candidate_profile_id" => candidate_profile_id
      }

      case status() do
        {:ok, %{"Self" => %{"Online" => true}}} ->
          {:ok, metadata}

        _offline ->
          {:error, :tailnet_candidate_unavailable, metadata}
      end
    else
      _failure -> {:error, :tailnet_candidate_unavailable}
    end
  end

  def stage_enrollment(_auth_key, _change_id, _previous_profile_id),
    do: {:error, :authentication_failed}

  @spec commit_enrollment(map()) :: :ok | {:error, atom()}
  def commit_enrollment(metadata) do
    previous = Map.get(metadata, "previous_profile_id")
    candidate = Map.get(metadata, "candidate_profile_id")

    if is_binary(previous) and is_binary(candidate) and previous != candidate do
      remove_profile(previous)
    else
      :ok
    end
  end

  @spec rollback_enrollment(map()) :: :ok | {:error, atom()}
  def rollback_enrollment(metadata) do
    previous = Map.get(metadata, "previous_profile_id")
    candidate = Map.get(metadata, "candidate_profile_id")

    with true <- is_binary(previous),
         :ok <- switch_profile(previous),
         :ok <- maybe_remove_candidate(candidate, previous) do
      :ok
    else
      _failure -> {:error, :tailnet_rollback_failed}
    end
  end

  defp profiles do
    client = backend()

    with :ok <- ensure_started(),
         result <-
           daemon_call(
             fn -> client.cli(@server, "switch", ["--list", "--json"]) end,
             :profile_failed
           ),
         {:ok, profiles} when is_list(profiles) <- result do
      {:ok, profiles}
    else
      _failure -> {:error, :tailnet_profile_unavailable}
    end
  end

  defp switch_profile(profile_id) do
    client = backend()

    client
    |> daemon_cli("switch", [profile_id], :tailnet_rollback_failed)
    |> successful()
  end

  defp remove_profile(profile_id) do
    client = backend()

    client
    |> daemon_cli("switch", ["remove", profile_id], :tailnet_profile_cleanup_failed)
    |> successful()
  end

  defp maybe_remove_candidate(candidate, previous)
       when is_binary(candidate) and candidate != previous,
       do: remove_profile(candidate)

  defp maybe_remove_candidate(_candidate, _previous), do: :ok

  defp daemon_cli(client, command, arguments, fallback) do
    daemon_call(fn -> client.cli(@server, command, arguments) end, fallback)
  end

  defp backend, do: Application.get_env(:nerves_gate, :tailscale_backend, Elixir.Tailscale)
  defp manager, do: Application.get_env(:nerves_gate, :tailscale_manager, Manager)

  defp successful(:ok), do: :ok
  defp successful({:ok, _output}), do: :ok
  defp successful(_failure), do: {:error, :operation_failed}

  # Calls into the separately supervised daemon may exit while it is restarting.
  # Convert that expected process-boundary failure; programming errors still crash.
  defp daemon_call(function, fallback) do
    function.()
  catch
    :exit, _reason -> {:error, fallback}
  end
end
