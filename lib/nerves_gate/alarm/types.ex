defmodule NervesGate.Alarm.CommissioningRequired do
  @moduledoc "The device needs local commissioning."
end

defmodule NervesGate.Alarm.CommissioningUnavailable do
  @moduledoc "No commissioning interface could be enabled."
end

defmodule NervesGate.Alarm.LinkFailure do
  @moduledoc "Tagged by the interface with missing physical link."
end

defmodule NervesGate.Alarm.DHCPFailed do
  @moduledoc "Tagged by the interface where DHCP failed."
end

defmodule NervesGate.Alarm.IPAddressUnavailable do
  @moduledoc "Tagged by a statically configured interface with no IPv4 address."
end

defmodule NervesGate.Alarm.MissingRoute do
  @moduledoc "No default route exists."
end

defmodule NervesGate.Alarm.DNSFailure do
  @moduledoc "DNS resolution failed persistently."
end

defmodule NervesGate.Alarm.InternetUnavailable do
  @moduledoc "HTTPS Internet verification failed persistently."
end

defmodule NervesGate.Alarm.StorageFailure do
  @moduledoc "Persistent storage is unavailable or corrupt."
end

defmodule NervesGate.Alarm.TailscaleBinaryFailure do
  @moduledoc "The pinned Tailscale binary set is unavailable."
end

defmodule NervesGate.Alarm.TailscaleAuthenticationRequired do
  @moduledoc "Tailscale enrollment is required."
end

defmodule NervesGate.Alarm.TailscaleOffline do
  @moduledoc "Tailscale is offline."
end

defmodule NervesGate.Alarm.DistributionFailure do
  @moduledoc "Distributed Erlang could not start."
end

defmodule NervesGate.Alarm.DegradedCluster do
  @moduledoc "One or more discovered gateway peers are disconnected."
end
