defmodule NervesGate.Tailnet.Enrollment do
  @moduledoc "Applies NervesGate's candidate transaction to typed Tailscale profiles."

  alias NervesGate.Identity

  @ready_timeout 30_000

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
         :ok <-
           client.login(
             auth_key: auth_key,
             hostname: Identity.get().hostname,
             nickname: nickname,
             accept_dns: false
           ),
         {:ok, profile} <- client.current_profile() do
      metadata = %{
        "previous_profile_id" => previous_profile_id,
        "candidate_profile_id" => profile.id
      }

      with :ok <-
             client.await_online(
               timeout: @ready_timeout,
               require: [:authenticated, :tailscale_ipv4]
             ),
           :ok <- client.set(ssh: false) do
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

  defp cleanup_untracked_profile(_client, previous) when is_binary(previous), do: :ok

  defp cleanup_untracked_profile(client, nil) do
    case client.profiles() do
      {:ok, profiles} -> remove_profiles(client, profiles)
      {:error, _reason} = error -> error
    end
  end

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
