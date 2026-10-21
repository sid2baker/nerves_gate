# Dedicated opt-in tailnet CI bench. Never put authentication keys in this file.
%{
  firmware: :local,
  devices: %{
    gateway_a: %{network: %{internet: :lan1}},
    gateway_b: %{network: %{internet: :lan1}},
    gateway_c: %{network: %{internet: :lan1}}
  }
}
