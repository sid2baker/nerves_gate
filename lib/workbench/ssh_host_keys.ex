defmodule Workbench.SSHHostKeys do
  @moduledoc """
  Accept only a host key whose SHA-256 fingerprint the gateway reported over
  authenticated distribution. `known_hosts` is neither read nor written.
  """
  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _peer, _port, _algorithm, options) do
    pinned = options |> Keyword.fetch!(:key_cb_private) |> Keyword.fetch!(:fingerprints)
    to_string(:ssh.hostkey_fingerprint(:sha256, key)) in pinned
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
