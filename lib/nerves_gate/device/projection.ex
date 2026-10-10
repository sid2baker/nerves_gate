defmodule NervesGate.Device.Projection do
  @moduledoc false
  alias NervesGate.Config
  alias NervesGate.Device.Error

  def build(%{status: status, actions: actions}) do
    %{
      version: 1,
      system: %{firmware: NervesGate.version(), target: to_string(NervesGate.target())},
      network: network(status),
      actions: actions
    }
  end

  defp network(nil) do
    %{
      available: false,
      desired: nil,
      pending: nil,
      observed: nil,
      defaults: Config.defaults()["network"],
      setup_completed: false,
      recovering: false,
      ready: false,
      error: Error.from(:unavailable)
    }
  end

  defp network(status) do
    %{
      available: true,
      desired: status.config && status.config["network"],
      pending: status.trial,
      observed: status.observed,
      defaults: Config.defaults()["network"],
      setup_completed: status.config != nil and status.config["setup_completed"],
      recovering: status.recovering,
      ready: status.ready,
      error: status.error
    }
  end
end
