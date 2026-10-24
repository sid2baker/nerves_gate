# Ordinary data, not a scenario DSL. The simulator site edits the devices and
# their Internet wiring. All devices use the same current firmware build.
%{
  firmware: :local,
  devices: %{gateway_a: %{network: %{internet: :lan1}}, gateway_b: %{network: %{internet: :lan2}}}
}
