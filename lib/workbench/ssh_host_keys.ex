defmodule Workbench.SSHHostKeys do
  @moduledoc "Verify the requested hostname, not OTP's resolved peer address, against known_hosts."
  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _resolved_peer, port, algorithm, options) do
    host = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:host)
    :ssh_file.is_host_key(key, host, port, algorithm, options)
  end

  @impl true
  def user_key(algorithm, options) do
    if options[:key_cb_private][:agent],
      do: :ssh_agent.user_key(algorithm, options),
      else: :ssh_file.user_key(algorithm, options)
  end

  @impl true
  defdelegate sign(key, data, options), to: :ssh_agent

  @impl true
  def add_host_key(_host, _port, _key, _options), do: {:error, :host_key_not_accepted}
end
