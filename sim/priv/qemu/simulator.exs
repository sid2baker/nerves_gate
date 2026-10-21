# Ordinary data. Devices stay stopped until explicitly started.
%{
  firmware: :local,
  devices: %{gateway_a: %{network: %{internet: :lan1}}, gateway_b: %{network: %{internet: :lan2}}}
}
