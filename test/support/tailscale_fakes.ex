defmodule NervesGate.TestTailscaleClient do
  @moduledoc false

  alias Tailscale.Preferences
  alias Tailscale.Profile
  alias Tailscale.Status

  def start_link(initial \\ %{}) do
    Agent.start_link(fn -> defaults() |> Map.merge(initial) end, name: __MODULE__)
  end

  def reset(initial \\ %{}) do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    start_link(initial)
  end

  def state, do: Agent.get(__MODULE__, & &1)
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  def await_ready(_options), do: result(:await_ready)
  def await_online(_options), do: result(:await_online)

  def login(options), do: Agent.get_and_update(__MODULE__, &login_result(&1, options))

  def profiles, do: Agent.get(__MODULE__, &{:ok, &1.profiles})

  def current_profile do
    Agent.get(__MODULE__, fn state ->
      case Enum.filter(state.profiles, & &1.selected?) do
        [profile] -> {:ok, profile}
        [] -> {:error, :no_current_profile}
        _profiles -> {:error, :multiple_current_profiles}
      end
    end)
  end

  def logout do
    Agent.update(__MODULE__, fn state ->
      %{state | profiles: Enum.reject(state.profiles, & &1.selected?)}
    end)
  end

  def switch_profile(profile_id) do
    Agent.update(__MODULE__, fn state ->
      %{state | profiles: Enum.map(state.profiles, &%{&1 | selected?: &1.id == profile_id})}
    end)
  end

  def remove_profile(profile_id) do
    Agent.update(__MODULE__, fn state ->
      %{state | profiles: Enum.reject(state.profiles, &(&1.id == profile_id))}
    end)
  end

  def set(changes) do
    Agent.update(__MODULE__, fn state ->
      preferences =
        Enum.reduce(changes, state.preferences, fn
          {:hostname, value}, preferences -> %{preferences | hostname: value}
          {:accept_dns, value}, preferences -> %{preferences | accept_dns: value}
          {:ssh, value}, preferences -> %{preferences | ssh: value}
          {:advertise_routes, value}, preferences -> %{preferences | advertised_routes: value}
        end)

      %{state | preferences: preferences}
    end)
  end

  def status, do: Agent.get(__MODULE__, &{:ok, &1.status})
  def advertised_routes, do: Agent.get(__MODULE__, &{:ok, &1.preferences.advertised_routes})

  def route_status do
    Agent.get(__MODULE__, fn state ->
      routes = state.preferences.advertised_routes
      {:ok, %{advertised: routes, approved: routes, primary: routes}}
    end)
  end

  defp login_result(%{login: :ok} = state, options),
    do: apply_login(state, options, :ok)

  defp login_result(%{login: {:applied, reply}} = state, options),
    do: apply_login(state, options, reply)

  defp login_result(state, _options), do: {state.login, state}

  defp apply_login(state, options, reply) do
    candidate = %Profile{
      id: "candidate-profile",
      nickname: Keyword.get(options, :nickname),
      selected?: state.select_after_login
    }

    profiles = [candidate | Enum.map(state.profiles, &%{&1 | selected?: false})]
    {reply, %{state | profiles: profiles}}
  end

  defp result(key), do: Agent.get_and_update(__MODULE__, &take_result(&1, key))

  defp take_result(state, key) do
    case Map.fetch!(state, key) do
      {:sequence, [result | remaining]} ->
        next = if remaining == [], do: result, else: {:sequence, remaining}
        {result, Map.put(state, key, next)}

      result ->
        {result, state}
    end
  end

  defp defaults do
    %{
      await_ready: :ok,
      await_online: :ok,
      login: :ok,
      select_after_login: true,
      profiles: [],
      preferences: %Preferences{},
      status: %Status{}
    }
  end
end
