# Dedicated opt-in tailnet CI bench. Never put authentication keys in this file.
%{
  firmware_project: "../firmware",
  firmware: "../firmware/_build/x86_64_dev/nerves/images/nerves_gate.fw",
  devices: %{
    gateway_a: %{network: %{internet: :lan1}},
    gateway_b: %{network: %{internet: :lan1}},
    gateway_c: %{network: %{internet: :lan1}}
  }
}
