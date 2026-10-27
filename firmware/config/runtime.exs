import Config

if config_target() == :x86_64 do
  # The disk serial carries the virtual hardware's actual private management IP.
  # inet.gethostname/0 returns only the short name before the first dot.
  "qemu-" <> address = File.read!("/proc/sys/kernel/hostname") |> String.trim()
  {:ok, {a, b, _c, d}} = :inet.parse_ipv4_address(to_charlist(address))
  true = d in 2..254 and (a == 10 or (a == 172 and b in 16..31) or (a == 192 and b == 168))
  config :nerves_gate, development_node: String.to_atom("nerves_gate@#{address}")

  config :vintage_net,
    config: [
      # Recovery must hash the same full serial as the simulator, not the
      # shortened hostname returned by inet.gethostname/0.
      {"usb0", %{type: VintageNetDirect, vintage_net_direct: %{hostname: "qemu-#{address}"}}},
      {"eth2",
       %{type: VintageNetEthernet, ipv4: %{method: :static, address: address, prefix_length: 24}}}
    ]
end

# No shared firmware secret. Sessions intentionally expire on reboot.
config :nerves_gate, NervesGateWeb.Endpoint,
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
