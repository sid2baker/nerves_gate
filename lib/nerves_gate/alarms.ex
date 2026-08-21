defmodule NervesGate.Alarms do
  @moduledoc "Safe Alarmist facade. Alarm descriptions never contain caller data."

  alias NervesGate.Alarm

  @descriptions %{
    Alarm.CommissioningRequired => "Device commissioning is required",
    Alarm.CommissioningUnavailable => "No local commissioning interface is available",
    Alarm.LinkFailure => "Physical network link is unavailable",
    Alarm.DHCPFailed => "DHCP did not provide usable connectivity",
    Alarm.IPAddressUnavailable => "The configured interface has no IPv4 address",
    Alarm.MissingRoute => "Default network route is unavailable",
    Alarm.DNSFailure => "DNS resolution is unavailable",
    Alarm.InternetUnavailable => "Internet HTTPS connectivity is unavailable",
    Alarm.NetworkFlapping => "Network connectivity is unstable",
    Alarm.StorageFailure => "Persistent storage is unavailable or corrupt",
    Alarm.TailscaleBinaryFailure => "Pinned Tailscale binaries are unavailable or invalid",
    Alarm.TailscaleAuthenticationRequired => "Tailscale authentication is required",
    Alarm.TailscaleOffline => "Tailscale is offline",
    Alarm.TailscaleUnstable => "Tailscale connectivity is unstable",
    Alarm.DistributionFailure => "BEAM distribution is unavailable",
    Alarm.DegradedCluster => "The expected cluster is degraded"
  }

  @spec set(Alarmist.alarm_id()) :: :ok
  def set(id) do
    :alarm_handler.set_alarm({id, description(id)})
  end

  @spec clear(Alarmist.alarm_id()) :: :ok
  def clear(id) do
    :alarm_handler.clear_alarm(id)
  end

  @spec active() :: [map()]
  def active do
    Alarmist.get_alarms(level: :debug)
    |> Enum.map(fn {id, description} ->
      %{id: encode_id(id), description: description}
    end)
    |> Enum.sort_by(& &1.id)
  catch
    :exit, _reason -> []
  end

  @spec report_connectivity(String.t(), map(), :dhcp | :static) :: :ok
  def report_connectivity(interface, checks, method \\ :dhcp) do
    toggle({Alarm.LinkFailure, interface}, checks.physical_link != :ok)
    toggle({Alarm.DHCPFailed, interface}, method == :dhcp and checks.ip_address != :ok)

    toggle(
      {Alarm.IPAddressUnavailable, interface},
      method == :static and checks.ip_address != :ok
    )

    toggle(Alarm.MissingRoute, checks.default_route != :ok)
    toggle(Alarm.DNSFailure, checks.dns != :ok)
    toggle(Alarm.InternetUnavailable, checks.internet_https != :ok)
    :ok
  end

  @spec toggle(Alarmist.alarm_id(), boolean()) :: :ok
  def toggle(id, true), do: set(id)
  def toggle(id, false), do: clear(id)

  defp description(id) do
    id
    |> Alarmist.alarm_type()
    |> then(&Map.get(@descriptions, &1, "Operational condition requires attention"))
  end

  defp encode_id(id) when is_atom(id), do: inspect(id)

  defp encode_id(id) when is_tuple(id) do
    id
    |> Tuple.to_list()
    |> Enum.map_join(":", fn value ->
      if is_atom(value), do: inspect(value), else: to_string(value)
    end)
  end
end

defmodule NervesGate.Alarms.Reporter do
  @moduledoc false
  use GenServer

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    :ok = Alarmist.subscribe_all()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Alarmist.Event{} = event, state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "alarms", {:alarms_changed, event.state})
    {:noreply, state}
  end
end

defmodule NervesGate.Alarm.NetworkFlapping do
  @moduledoc "Internet connectivity changed too frequently."
  use Alarmist.Alarm, level: :warning

  alarm_if do
    hold(
      intensity(NervesGate.Alarm.InternetUnavailable, 4, :timer.minutes(5)),
      :timer.minutes(10)
    )
  end
end

defmodule NervesGate.Alarm.TailscaleUnstable do
  @moduledoc "Tailscale connectivity changed too frequently."
  use Alarmist.Alarm, level: :warning

  alarm_if do
    hold(intensity(NervesGate.Alarm.TailscaleOffline, 4, :timer.minutes(5)), :timer.minutes(10))
  end
end
