defmodule TailnetSubrouter do
  @moduledoc "Opt-in subnet routing over the gateway's existing tailnet. Startup never configures or advertises anything."
  use GenServer
  alias NervesGateSDK.Network

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Select an operator-enabled interface and an unused gateway-side IPv4 address. Does not advertise."
  def configure(interface, address, prefix),
    do: GenServer.call(__MODULE__, {:configure, interface, address, prefix}, 75_000)

  @doc "Explicitly advertise the configured, physically ready local subnet once."
  def enable, do: GenServer.call(__MODULE__, :enable, 75_000)

  @doc "Withdraw the app's advertisement and release its interface. Incomplete cleanup is an error, not success."
  def disable, do: GenServer.call(__MODULE__, :disable, 75_000)
  def status, do: GenServer.call(__MODULE__, :status)
  def interfaces, do: GenServer.call(__MODULE__, :interfaces)
  def health_check, do: if(Process.whereis(__MODULE__), do: :ok, else: {:error, :not_running})

  def init(_), do: {:ok, false}

  # All SDK calls run in this supervised owner, never a Task or UI caller.
  def handle_call({:configure, interface, address, prefix}, _, _attempted) do
    result = Network.claim_local(interface, address, prefix)

    reply =
      case result do
        {:ok, _ref} -> :ok
        error -> error
      end

    {:reply, reply, true}
  end

  def handle_call(:interfaces, _, attempted), do: {:reply, Network.interfaces(), attempted}

  def handle_call(:enable, _, false), do: {:reply, {:error, :configure_first}, false}
  def handle_call(:disable, _, false), do: {:reply, :ok, false}
  def handle_call(:status, _, false), do: {:reply, %{state: :disabled}, false}

  def handle_call(:enable, _, true) do
    result =
      case Network.local_status() do
        {:ok, %Network.Local{ref: ref}} -> Network.advertise_local(ref)
        {:ok, nil} -> {:error, :configure_first}
        error -> error
      end

    {:reply, result, true}
  end

  def handle_call(:disable, _, true) do
    result =
      case Network.local_status() do
        {:ok, nil} -> :ok
        {:ok, %Network.Local{ref: ref}} -> Network.release_local(ref)
        error -> error
      end

    {:reply, result, result != :ok}
  end

  def handle_call(:status, _, true), do: {:reply, public_status(Network.local_status()), true}

  @doc false
  def public_status({:ok, nil}), do: %{state: :disabled}

  def public_status({:ok, %Network.Local{} = local}) do
    %{
      state: local.phase,
      interface: local.interface,
      address: local.address,
      prefix: local.prefix,
      subnet: local.subnet,
      link_ready: local.ready?,
      advertised: local.advertised?,
      tailnet_approval: local.approval,
      error: local.error
    }
  end

  def public_status({:error, reason}), do: %{state: :unavailable, error: reason}
end
