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
      # Approved dependency exception is internal to Jido, not an application API.
      {["NervesGate.*", "NervesGateWeb.*"], ["Runic.*"]},
      {"NervesGate.*", ["NervesGateWeb.*"], except: ["NervesGate.Application"]},
      {"NervesGateWeb.*",
       [
         "Jido.*",
         "NervesGate.Network.Runtime.*",
         "NervesGate.Network.Agent.*",
         "NervesGate.Network.status",
         "NervesGate.Network.validate",
         "NervesGate.Network.propose",
         "NervesGate.Network.confirm",
         "NervesGate.Network.cancel",
         "NervesGate.Remote.command",
         "NervesGate.Remote.status",
         "NervesGate.Remote.login_url",
         "VintageNet.configure",
         "VintageNet.Persistence.*",
         "Tailscale.*"
       ]},
      {["NervesGate.Network.Actions.*", "NervesGate.Status"],
       [
         "GenServer.call",
         "System.cmd",
         "File.write*",
         "NervesGate.Network.Runtime.*",
         "NervesGate.Network.Adapter.*",
         "NervesGate.Remote.Adapter.*",
         "VintageNet.configure",
         "VintageNet.Persistence.*",
         "Tailscale.*"
       ]}
    ]
  ]
]
