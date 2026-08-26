defmodule NervesGateQEMU.Environment do
  @moduledoc "Loads integration inputs without exposing their values in diagnostics."

  alias NervesGateQEMU.Runner

  @auth_key "NERVES_GATE_TAILSCALE_AUTH_KEY"

  @spec auth_key() :: {:ok, String.t()} | {:error, term()}
  def auth_key do
    case present(System.get_env(@auth_key)) do
      nil -> read_dotenv(@auth_key)
      value -> {:ok, value}
    end
  end

  @spec cluster_group() :: String.t()
  def cluster_group do
    present(System.get_env("NERVES_GATE_QEMU_CLUSTER_GROUP")) || "nerves-gate-integration"
  end

  defp read_dotenv(key) do
    path = Path.join(Runner.project_root(), ".env")

    with {:ok, contents} <- File.read(path),
         value when is_binary(value) <- dotenv_value(contents, key),
         value when is_binary(value) <- present(value) do
      {:ok, value}
    else
      {:error, :enoent} -> {:error, {:missing_environment, key, path}}
      {:error, reason} -> {:error, {:environment_unavailable, reason}}
      nil -> {:error, {:missing_environment, key, path}}
    end
  end

  defp dotenv_value(contents, key) do
    prefix = key <> "="

    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      line = String.trim(line)

      if String.starts_with?(line, prefix) do
        line
        |> String.replace_prefix(prefix, "")
        |> String.trim()
        |> unquote_value()
      end
    end)
  end

  defp unquote_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    suffix = <<quote>>
    if String.ends_with?(rest, suffix), do: String.trim_trailing(rest, suffix), else: rest
  end

  defp unquote_value(value), do: value

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil
end
