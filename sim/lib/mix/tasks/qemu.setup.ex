defmodule Mix.Tasks.Qemu.Setup do
  @moduledoc false
  use Mix.Task

  # Workstation prerequisites for building firmware and running QEMU devices.
  # The root `mix setup` prepares the firmware inputs itself.
  @impl true
  def run([]) do
    NervesGateSim.Prerequisites.check!(~w(git make cc pkg-config inotifywait))

    unless :erlang.system_info(:otp_release) == ~c"29" do
      Mix.raise("Use OTP 29 and Elixir 1.20; mise.toml pins the development toolchain.")
    end
  end

  def run(_), do: Mix.raise("Usage: mix setup (from the repository root)")
end
