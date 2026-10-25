{:ok, _} = Application.ensure_all_started(:req)

defmodule UpdateCellularProviders do
  @moduledoc false
  @source "https://raw.githubusercontent.com/GNOME/mobile-broadband-provider-info"

  def run(revision) do
    xml = Req.get!("#{@source}/#{revision}/serviceproviders.xml").body
    # The upstream DTD documents the schema; generation must not fetch entities.
    xml = String.replace(xml, ~r/<!DOCTYPE[^>]*>/, "")
    if String.contains?(xml, "<!ENTITY"), do: raise("XML entities are not allowed")
    {document, []} = :xmerl_scan.string(:binary.bin_to_list(xml), quiet: true)

    profiles =
      for provider <- nodes("/serviceproviders/country/provider[gsm]", document),
          apn <- nodes("gsm/apn", provider),
          internet?(apn),
          networks =
            Enum.map(nodes("gsm/network-id", provider), &(text("@mcc", &1) <> text("@mnc", &1))),
          networks != [],
          apn_value = text("@value", apn),
          Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,99}\z/, apn_value) do
        %{
          name: text("name[1]", provider),
          names: Enum.map(nodes("name", provider), &text(".", &1)),
          networks: networks,
          gid1: Enum.map(nodes("gsm/gid1", provider), &text(".", &1)),
          apn: apn_value,
          plan: text("name[1]", apn),
          username: text("username", apn),
          password: text("password", apn),
          authentication: text("authentication/@method", apn)
        }
      end

    path = "firmware/priv/cellular/providers.json"
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(
        %{source: @source, revision: revision, license: "Public domain", profiles: profiles},
        pretty: true
      ) <> "\n"
    )

    File.write!("firmware/priv/cellular/COPYING", Req.get!("#{@source}/#{revision}/COPYING").body)
    IO.puts("Updated #{length(profiles)} public carrier profiles at #{revision}")
  end

  defp internet?(apn) do
    usage = text("usage/@type", apn)

    usage == "internet" or
      (usage == "" and nodes("mmsc|mmsproxy", apn) == [] and
         not String.contains?(String.downcase(text("@value", apn)), "wap"))
  end

  defp nodes(path, document), do: :xmerl_xpath.string(String.to_charlist(path), document)

  defp text(path, document) do
    {:xmlObj, :string, value} = nodes("string(#{path})", document)
    value |> List.to_string() |> String.trim()
  end
end

case System.argv() do
  [revision] -> UpdateCellularProviders.run(revision)
  _ -> raise "Usage: mix run --no-start scripts/update_cellular_providers.exs <upstream commit>"
end
