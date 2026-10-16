# Ordinary data, not a scenario DSL. Both devices use the same firmware build.
# Set factory_firmware to a compatible older artifact for cross-version work.
%{
  firmware: "_build/x86_64_dev/nerves/images/nerves_gate.fw",
  devices: %{
    gateway_a: %{network: %{internet: :lan1}},
    gateway_b: %{network: %{internet: :lan2}}
  }
}
