defmodule NervesGateQEMU.Commissioner do
  @moduledoc "Commissions gateways through the public backend command API."

  alias NervesGateQEMU.{Gateway, Runner}

  @spec commission(Runner.device(), String.t(), String.t()) :: :ok
  def commission(device, auth_key, group)
      when is_binary(auth_key) and is_binary(group) do
    case Gateway.fetch(device) do
      {:ok, status} ->
        if Gateway.configured?(status),
          do: :ok,
          else: drive(device, auth_key, group, command_id(), 3)

      {:error, reason} ->
        raise "#{device.id} status unavailable: #{inspect(reason)}"
    end
  end

  defp drive(device, auth_key, group, connection_id, tailnet_attempts) do
    status = fetch!(device)
    configuration = get_in(status, ["local", "state", "configuration"]) || %{}

    cond do
      configuration["configured"] == true ->
        :ok

      is_nil(configuration["pending"]) ->
        command!(device, "internet", %{
          "connection_id" => connection_id,
          "device" => %{"name" => gateway_name(device)},
          "internet" => %{"method" => "dhcp"}
        })

        drive(device, auth_key, group, connection_id, tailnet_attempts)

      configuration["pending"]["phase"] == "tailnet" ->
        candidate_id = configuration["pending"]["id"]
        submit_tailnet(device, candidate_id, auth_key, tailnet_attempts)
        drive(device, auth_key, group, connection_id, tailnet_attempts)

      configuration["pending"]["phase"] == "cluster" ->
        candidate_id = configuration["pending"]["id"]

        command!(device, "cluster", %{
          "candidate_id" => candidate_id,
          "cluster" => %{"group" => group}
        })

        drive(device, auth_key, group, connection_id, tailnet_attempts)

      configuration["pending"]["phase"] == "confirmation" ->
        tailnet_ipv4 = await_tailnet_ipv4(device, 60_000)
        keep!(device, tailnet_ipv4, configuration["pending"]["id"])
        await_configured(device, 60_000)

      true ->
        raise "#{device.id} commissioning reached an unknown backend phase"
    end
  end

  defp submit_tailnet(device, candidate_id, auth_key, attempts) do
    case Gateway.command(
           device,
           "tailnet",
           %{"candidate_id" => candidate_id, "auth_token" => auth_key}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        if pending_phase(device) != "tailnet" do
          :ok
        else
          retry_tailnet(device, candidate_id, auth_key, attempts, reason)
        end
    end
  end

  defp retry_tailnet(device, candidate_id, auth_key, attempts, _reason) when attempts > 1 do
    Process.sleep(5_000)
    submit_tailnet(device, candidate_id, auth_key, attempts - 1)
  end

  defp retry_tailnet(device, _candidate_id, _auth_key, _attempts, reason) do
    raise "#{device.id} Tailnet enrollment failed after retries: #{inspect(reason)}"
  end

  defp pending_phase(device) do
    device
    |> fetch!()
    |> get_in(["local", "state", "configuration", "pending", "phase"])
  end

  defp command!(device, command, params) do
    case Gateway.command(device, command, params) do
      :ok -> :ok
      {:error, reason} -> raise "#{device.id} #{command} command failed: #{inspect(reason)}"
    end
  end

  defp keep!(device, tailnet_ipv4, candidate_id) when is_binary(tailnet_ipv4) do
    case Gateway.command_at(
           "http://#{tailnet_ipv4}/",
           "keep",
           %{"candidate_id" => candidate_id}
         ) do
      :ok -> :ok
      {:error, reason} -> raise "#{device.id} keep command failed: #{inspect(reason)}"
    end
  end

  defp keep!(device, _tailnet_ipv4, _candidate_id) do
    raise "#{device.id} candidate has no Tailnet address for guarded acceptance"
  end

  defp fetch!(device) do
    case Gateway.fetch(device) do
      {:ok, status} -> status
      {:error, reason} -> raise "#{device.id} status unavailable: #{inspect(reason)}"
    end
  end

  defp await_tailnet_ipv4(device, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_tailnet_ipv4(device, deadline)
  end

  defp do_await_tailnet_ipv4(device, deadline) do
    ipv4 = device |> fetch!() |> get_in(["local", "state", "tailnet", "ipv4"])

    cond do
      is_binary(ipv4) ->
        ipv4

      System.monotonic_time(:millisecond) >= deadline ->
        raise "#{device.id} candidate has no Tailnet address for guarded acceptance"

      true ->
        Process.sleep(500)
        do_await_tailnet_ipv4(device, deadline)
    end
  end

  defp await_configured(device, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_configured(device, deadline)
  end

  defp do_await_configured(device, deadline) do
    if device |> fetch!() |> Gateway.configured?() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "#{device.id} candidate was not durably accepted"
      else
        Process.sleep(500)
        do_await_configured(device, deadline)
      end
    end
  end

  defp gateway_name(device), do: "nervesgate-#{String.downcase(device.id)}"

  defp command_id do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
