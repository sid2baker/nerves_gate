defmodule NervesGate.Tailnet.Enrollment do
  @moduledoc "Applies NervesGate's candidate transaction to typed Tailscale profiles."

  alias NervesGate.Identity

  @ready_timeout 90_000

  @spec stage(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()} | {:error, atom(), map()}
  def stage(auth_key, change_id, previous_profile_id)
      when is_binary(auth_key) and byte_size(auth_key) in 8..512 and
             is_binary(change_id) and
             (is_binary(previous_profile_id) or is_nil(previous_profile_id)) do
    client = client()
    nickname = "nervesgate-pending-#{String.slice(change_id, 0, 12)}"

    with :ok <- client.await_ready(timeout: 10_000),
         :ok <- cleanup_untracked_profile(client, previous_profile_id),
         {:ok, profile} <- login_candidate(client, auth_key, nickname) do
      metadata = %{
        "previous_profile_id" => previous_profile_id,
        "candidate_profile_id" => profile.id
      }

      deadline = System.monotonic_time(:millisecond) + @ready_timeout

      with :ok <- await_candidate_online(client, deadline),
           :ok <- set_candidate_preferences(client, deadline) do
        {:ok, metadata}
      else
        {:error, :online_timeout} -> {:error, :tailnet_online_timeout, metadata}
        {:error, {:online_timeout, _status}} -> {:error, :tailnet_online_timeout, metadata}
        {:error, _reason} -> {:error, :tailnet_candidate_unavailable, metadata}
      end
    else
      {:error, _reason} -> {:error, :tailnet_candidate_unavailable}
    end
  end

  def stage(_auth_key, _change_id, _previous_profile_id),
    do: {:error, :authentication_failed}

  @spec select(String.t() | nil) :: :ok | {:error, term()}
  def select(nil), do: cleanup_untracked_profile(client(), nil)
  def select(profile_id) when is_binary(profile_id), do: client().switch_profile(profile_id)

  @spec commit(map()) :: :ok | {:error, term()}
  def commit(metadata) do
    previous = Map.get(metadata, "previous_profile_id")
    candidate = Map.get(metadata, "candidate_profile_id")

    if is_binary(previous) and is_binary(candidate) and previous != candidate,
      do: client().remove_profile(previous),
      else: :ok
  end

  @spec rollback(map()) :: :ok | {:error, atom()}
  def rollback(metadata) do
    previous = Map.get(metadata, "previous_profile_id")
    candidate = Map.get(metadata, "candidate_profile_id")

    case {previous, candidate} do
      {previous, candidate} when is_binary(previous) ->
        with :ok <- client().switch_profile(previous),
             :ok <- maybe_remove_candidate(candidate, previous) do
          :ok
        else
          _failure -> {:error, :tailnet_rollback_failed}
        end

      {nil, candidate} when is_binary(candidate) ->
        case cleanup_untracked_profile(client(), nil) do
          :ok -> :ok
          _failure -> {:error, :tailnet_rollback_failed}
        end

      {nil, nil} ->
        :ok

      _invalid ->
        {:error, :tailnet_rollback_failed}
    end
  end

  @doc false
  @spec current_profile_id() :: {:ok, String.t() | nil} | {:error, term()}
  def current_profile_id do
    case client().current_profile() do
      {:ok, profile} -> {:ok, profile.id}
      {:error, :no_current_profile} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp await_candidate_online(client, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 1)

    case client.await_online(
           timeout: timeout,
           require: [:authenticated, :tailscale_ipv4]
         ) do
      :ok -> :ok
      {:error, reason} = error -> retry_transient(client, deadline, reason, error, :online)
    end
  end

  defp set_candidate_preferences(client, deadline) do
    case client.set(ssh: false) do
      :ok -> :ok
      {:error, reason} = error -> retry_transient(client, deadline, reason, error, :preferences)
    end
  end

  defp retry_transient(client, deadline, reason, error, operation) do
    if transient?(reason) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(500)

      case operation do
        :online -> await_candidate_online(client, deadline)
        :preferences -> set_candidate_preferences(client, deadline)
      end
    else
      error
    end
  end

  defp transient?(reason),
    do: reason in [:server_unavailable, :daemon_restarting, :socket_unavailable]

  defp login_candidate(client, auth_key, nickname) do
    result =
      client.login(
        auth_key: auth_key,
        hostname: Identity.get().hostname,
        nickname: nickname,
        accept_dns: false
      )

    case select_candidate_profile(client, nickname) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} when result == :ok -> {:error, :candidate_profile_not_found}
      {:error, _reason} -> result
    end
  end

  defp select_candidate_profile(client, nickname) do
    with {:ok, profiles} <- client.profiles(),
         %Tailscale.Profile{} = profile <- Enum.find(profiles, &(&1.nickname == nickname)),
         :ok <- maybe_switch_profile(client, profile) do
      {:ok, %{profile | selected?: true}}
    else
      nil -> {:error, :candidate_profile_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_switch_profile(_client, %{selected?: true}), do: :ok
  defp maybe_switch_profile(client, profile), do: client.switch_profile(profile.id)

  defp cleanup_untracked_profile(_client, previous) when is_binary(previous), do: :ok

  defp cleanup_untracked_profile(client, nil) do
    with {:ok, profiles} <- client.profiles(),
         :ok <- logout_selected_profile(client, profiles),
         {:ok, remaining_profiles} <- client.profiles() do
      remove_profiles(client, remaining_profiles)
    end
  end

  defp logout_selected_profile(client, profiles) do
    if Enum.any?(profiles, & &1.selected?) do
      result =
        if function_exported?(client, :logout, 0),
          do: client.logout(),
          else: client.cli("logout", [], mode: :mutation)

      normalize_mutation_result(result)
    else
      :ok
    end
  end

  defp normalize_mutation_result(:ok), do: :ok
  defp normalize_mutation_result({:ok, _result}), do: :ok
  defp normalize_mutation_result({:error, _reason} = error), do: error

  defp remove_profiles(client, profiles) do
    Enum.reduce_while(profiles, :ok, fn profile, :ok ->
      case client.remove_profile(profile.id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_remove_candidate(candidate, previous)
       when is_binary(candidate) and candidate != previous,
       do: client().remove_profile(candidate)

  defp maybe_remove_candidate(_candidate, _previous), do: :ok

  defp client, do: Application.get_env(:nerves_gate, :tailscale_client, Tailscale)
end
