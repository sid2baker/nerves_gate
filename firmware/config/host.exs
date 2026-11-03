import Config

# Host builds provide checks, assets and components shared with the workbench.
# The application is not started here (see mix.exs), so no device services or
# gateway HTTP endpoint run on the workstation.

import_config "assets.exs"
