[
  layers: [
    web: "NervesGateWeb.*",
    public_api: "NervesGate",
    firmware_platform: ["NervesGate.Firmware.Platform", "NervesGate.Firmware.Platform.*"],
    projection: ["NervesGate.DeviceState", "NervesGate.DeviceState.*", "NervesGate.Session"]
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
      "NervesGate.Session.Supervisor",
      "NervesGate.StartupGate",
      "NervesGate.ShoehornHandler"
    ],
    forbidden_files: [
      "lib/nerves_gate/dependencies.ex",
      "lib/nerves_gate/retry.ex",
      "lib/nerves_gate/backoff.ex",
      "lib/nerves_gate/secret.ex",
      "lib/nerves_gate/session/supervisor.ex",
      "lib/nerves_gate/startup_gate.ex",
      "lib/nerves_gate/shoehorn_handler.ex"
    ]
  ]
]
