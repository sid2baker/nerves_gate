defmodule NervesGate.System do
  @moduledoc "Sanitized firmware and runtime identity, independent of device service availability."

  def info do
    %{
      firmware: Application.spec(:nerves_gate, :vsn) |> to_string(),
      target: Application.fetch_env!(:nerves_gate, :target) |> to_string(),
      node: Node.self(),
      elixir: System.version(),
      otp: System.otp_release()
    }
  end
end
