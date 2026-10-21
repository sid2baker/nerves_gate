defmodule Mix.Tasks.Dev.Ui do
  use Mix.Task
  @shortdoc "Open the gateway UI against an explicitly connected device"
  @requirements ["app.config"]
  def run(args), do: Dev.GatewayUI.run(args)
end
