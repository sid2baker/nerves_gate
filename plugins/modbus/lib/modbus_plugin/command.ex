defmodule ModbusPlugin.Command do
  @moduledoc """
  The plugin's single manual writer. It holds platform output claims as the
  actual calling PID so UI processes never own desired state. Claiming sets no
  target; releasing drops the desire without any physical write. Stopping this
  process releases every claim through ordinary platform owner fencing.
  """
  use GenServer
  alias NervesGateSDK.IO, as: SDKIO

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def claim(full_id), do: GenServer.call(__MODULE__, {:claim, full_id})
  def set(full_id, value), do: GenServer.call(__MODULE__, {:set, full_id, value})
  def release(full_id), do: GenServer.call(__MODULE__, {:release, full_id})
  def claims, do: GenServer.call(__MODULE__, :claims)

  @doc "Platform output snapshot (claimed?, desired, reported feedback) read as a managed process."
  def output(full_id), do: GenServer.call(__MODULE__, {:output, full_id})

  @impl true
  def init(_), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:claim, id}, _, claims) do
    case SDKIO.claim_output(id) do
      :ok -> {:reply, :ok, MapSet.put(claims, id)}
      error -> {:reply, error, claims}
    end
  end

  def handle_call({:set, id, value}, _, claims) do
    if MapSet.member?(claims, id),
      do: {:reply, SDKIO.set_output(id, value), claims},
      else: {:reply, {:error, :not_claimed}, claims}
  end

  def handle_call({:release, id}, _, claims) do
    case SDKIO.release_output(id) do
      :ok -> {:reply, :ok, MapSet.delete(claims, id)}
      error -> {:reply, error, claims}
    end
  end

  def handle_call(:claims, _, claims), do: {:reply, Enum.sort(claims), claims}
  def handle_call({:output, id}, _, claims), do: {:reply, SDKIO.output(id), claims}
end
