[
  source: [
    forbidden_modules: [
      "NervesGate.Device.Workflow",
      "NervesGate.Device.Actions",
      "NervesGate.Device.Projection",
      "NervesGate.SystemState"
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
         "NervesGate.Remote.Runtime.*",
         "NervesGate.Network.Agent.*",
         "NervesGate.Remote.Agent.*",
         "NervesGate.Connectivity.Agent.*",
         "NervesGate.Network.propose",
         "NervesGate.Network.confirm",
         "NervesGate.Network.cancel",
         "NervesGate.Remote.command",
         "NervesGate.Config.save",
         "VintageNet.configure",
         "Tailscale.*"
       ]},
      {[
         "NervesGate.Network.Actions.*",
         "NervesGate.Remote.Actions.*",
         "NervesGate.Connectivity.Actions.*",
         "NervesGate.Device.Selectors"
       ],
       [
         "GenServer.call",
         "System.cmd",
         "File.write*",
         "NervesGate.Config.save",
         "NervesGate.Network.Runtime.*",
         "NervesGate.Remote.Runtime.*",
         "NervesGate.Network.Adapter.*",
         "NervesGate.Remote.Adapter.*",
         "VintageNet.configure",
         "Tailscale.*"
       ]}
    ]
  ]
]
