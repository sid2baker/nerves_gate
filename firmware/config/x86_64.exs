import Config
import_config "firmware.exs"

# One QEMU development firmware, also used by all scenarios. Not the workstation.
# Same application as EC100; only virtual hardware differs. QEMU does not emulate
# EC100 buses, LEDs or the recovery button, so those adapters are disabled.
config :nerves_gate, :board, %{
  data_partition: "/sys/class/block/vda4/dev",
  # The simulator's prepared ext4 virtual SD card.
  plugins_device: "/dev/vdb",
  cellular: nil,
  hardware_adapter: nil,
  recovery_adapter: nil,
  indicators_adapter: nil
}

# Also log to the serial console, which the simulator records per boot as
# console-<boot>.log, so device logs are followable live and survive disk resets.
config :logger, backends: [RingLogger, :console]

# runtime.exs configures USB recovery and eth2's actual management IP from the
# virtual disk serial. eth2 is separate from eth0/eth1 and cannot be a trial port.
