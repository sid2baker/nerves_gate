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
  def cli(_server, _command, _arguments), do: {:ok, "ok"}
end

defmodule NervesGate.TestTailscaleManager do
  @moduledoc false

  def ensure_started, do: :ok
  def repair, do: :ok
end
