[
  layers: [
    web: "NervesGateWeb.*",
    public_api: "NervesGate",
    firmware_platform: ["NervesGate.Firmware.Platform", "NervesGate.Firmware.Platform.*"],
    projection: [
      "NervesGate.Client",
      "NervesGate.Fleet",
      "NervesGate.DeviceState",
      "NervesGate.DeviceState.*"
    ]
  ],
  deps: [
    forbidden: [
      {:firmware_platform, :projection},
      {:projection, :firmware_platform}
    ]
  ],
  calls: [
    forbidden: [
      {"NervesGate.*", ["NervesGateWeb.*"], except: ["NervesGate.Application"]}
    ]
  ],
  boundaries: [
    public: ["NervesGate"],
    internal: ["NervesGate.*"],
    internal_callers: [
      {"NervesGate.*", ["NervesGate", "NervesGate.*", "Mix.Tasks.NervesGate.*"]}
    ]
  ],
  source: [
    forbidden_modules: [
      "NervesGate.Dependencies",
      "NervesGate.Retry",
      "NervesGate.Backoff",
      "NervesGate.Secret",
      "NervesGate.Session",
      "NervesGate.Session.Supervisor",
      "NervesGate.DeviceState.Replica",
      "NervesGate.DeviceState.Replica.*",
      "NervesGate.Cluster.Peer",
      "NervesGate.Cluster.Peer.*",
      "NervesGate.Cluster.Supervisor",
      "NervesGate.AlarmistAdapter",
      "NervesGate.Alarms.Runtime",
      "NervesGate.*.Alarms",
      "NervesGate.StartupGate",
      "NervesGate.ShoehornHandler"
    ],
    forbidden_files: [
      "lib/nerves_gate/dependencies.ex",
      "lib/nerves_gate/retry.ex",
      "lib/nerves_gate/backoff.ex",
      "lib/nerves_gate/secret.ex",
      "lib/nerves_gate/session.ex",
      "lib/nerves_gate/session/**",
      "lib/nerves_gate/device_state/replica.ex",
      "lib/nerves_gate/device_state/replica/**",
      "lib/nerves_gate/cluster/peer.ex",
      "lib/nerves_gate/cluster/supervisor.ex",
      "lib/nerves_gate/alarmist_adapter.ex",
      "lib/nerves_gate/*/alarms.ex",
      "lib/nerves_gate/startup_gate.ex",
      "lib/nerves_gate/shoehorn_handler.ex"
    ]
  ]
]
