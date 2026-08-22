defmodule NervesGate.TestTailscaleClient do
  @moduledoc false

  def start_link(initial \\ {:error, :offline}) do
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def reset(initial) do
    if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    start_link(initial)
  end

  def put(result), do: Agent.update(__MODULE__, fn _old -> result end)
  def status, do: Agent.get(__MODULE__, & &1)
  def status(_server), do: status()
  def login(_server, _auth_key), do: Agent.get(__MODULE__, &Map.get(elem(&1, 1), :login, &1))

  def cli(_server, "switch", ["--list", "--json"]) do
    Agent.get(__MODULE__, fn
      {:ok, raw} -> {:ok, Map.get(raw, :profiles, [])}
      error -> error
    end)
  end

  def cli(_server, "login", arguments) do
    nickname =
      arguments
      |> Enum.find(&String.starts_with?(&1, "--nickname="))
      |> then(fn
        nil -> "candidate"
        value -> String.replace_prefix(value, "--nickname=", "")
      end)

    Agent.update(__MODULE__, fn {:ok, raw} ->
      profiles =
        raw
        |> Map.get(:profiles, [])
        |> Enum.map(&Map.put(&1, "selected", false))
        |> then(
          &[%{"id" => "candidate-profile", "nickname" => nickname, "selected" => true} | &1]
        )

      {:ok, raw |> Map.put(:profiles, profiles) |> Map.put("Self", %{"Online" => true})}
    end)

    {:ok, "ok"}
  end

  def cli(_server, "switch", ["remove", profile_id]) do
    Agent.update(__MODULE__, fn {:ok, raw} ->
      {:ok,
       Map.update(
         raw,
         :profiles,
         [],
         &Enum.reject(&1, fn profile -> profile["id"] == profile_id end)
       )}
    end)

    {:ok, "ok"}
  end

  def cli(_server, "switch", [profile_id]) do
    Agent.update(__MODULE__, fn {:ok, raw} ->
      profiles =
        raw
        |> Map.get(:profiles, [])
        |> Enum.map(&Map.put(&1, "selected", &1["id"] == profile_id))

      {:ok, Map.put(raw, :profiles, profiles)}
    end)

    {:ok, "ok"}
  end

  def cli(_server, _command, _arguments), do: {:ok, "ok"}
end

defmodule NervesGate.TestTailscaleManager do
  @moduledoc false

  def ensure_started, do: :ok
  def repair, do: :ok
end
