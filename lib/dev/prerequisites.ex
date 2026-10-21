defmodule Dev.Prerequisites do
  @moduledoc "Workstation requirements for the platform's real QEMU and firmware builds."
  def check! do
    NervesGateSim.Prerequisites.check!(~w(mksquashfs unsquashfs))
  end
end
