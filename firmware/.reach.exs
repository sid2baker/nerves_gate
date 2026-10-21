[
  source: [
    forbidden_modules: [
      "NervesGate.Device",
      "NervesGate.Device.*",
      "NervesGate.SystemState",
      "NervesGate.AtomicFile",
      "NervesGate.Network.TrialStore",
      "NervesGate.Network.Recovery",
      "NervesGate.Connectivity",
      "NervesGate.Connectivity.*",
      "NervesGate.Remote.Agent",
      "NervesGate.Remote.Runtime"
    ]
  ],
  calls: [
    forbidden: [
      {"NervesGate.*", ["NervesGateWeb.*"],
       except: ["NervesGate.Application"]},
      {"NervesGateWeb.*",
       [
         "Alarmist.*",
         "NervesGate.Alarms.*",
         "NervesGate.Network.status",
         "NervesGate.Network.validate",
         "NervesGate.Network.propose",
         "NervesGate.Network.confirm",
         "NervesGate.Network.cancel",
         "NervesGate.Network.scan",
         "NervesGate.Network.sharing",
         "NervesGate.Remote.connect",
         "NervesGate.Remote.configure",
         "NervesGate.Remote.disconnect",
         "NervesGate.Remote.sharing",
         "NervesGate.Remote.status",
         "NervesGate.Remote.login_url",
         "NervesGate.Equipment.status",
         "NervesGate.Equipment.scan",
         "NervesGate.Equipment.label",
         "NervesGate.Equipment.Linux.*",
         "NervesGate.Indicators.*",
         "NervesGate.Buses.*",
         "NervesGate.SSH.*",
         "NervesGate.Linux.*",
         "VintageNet.configure",
         "VintageNet.Persistence.*",
         "Tailscaled.*"
       ]},
      {["NervesGate.Network.Policy", "NervesGate.Status", "NervesGate.Projection"],
       [
         "GenServer.call",
         "Node.self",
         "System.version",
         "System.otp_release",
         "NervesGate.status",
         "NervesGate.status_input",
         "System.cmd",
         "File.write*",
         "NervesGate.Network.Adapter.*",
         "NervesGate.Remote.Adapter.*",
         "VintageNet.configure",
         "VintageNet.Persistence.*",
         "Tailscaled.*"
       ]}
    ]
  ]
]
