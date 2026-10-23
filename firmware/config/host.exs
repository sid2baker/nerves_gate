import Config

# Host builds provide checks, assets and components shared with the workbench.
# No device services or gateway HTTP endpoint start here. Native networking
# dependencies compile for their types but never start on the workstation.
config :nerves_gate, services: []

import_config "assets.exs"
