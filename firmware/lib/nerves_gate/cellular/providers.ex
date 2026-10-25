defmodule NervesGate.Cellular.Providers do
  @moduledoc "Offline carrier defaults. SIM identifiers and authentication stay inside the modem domain."
  alias NervesGate.Cellular.Authentication

  @external_resource Application.app_dir(:nerves_gate, "priv/cellular/providers.json")
  @profiles @external_resource
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("profiles")
            |> Enum.map(fn profile ->
              id =
                [profile["name"], profile["plan"], profile["apn"], Enum.sort(profile["gid1"])]
                |> Jason.encode!()
                |> then(&:crypto.hash(:sha256, &1))
                |> Base.encode16(case: :lower)

              Map.put(profile, "id", id)
            end)

  # EF_SPN identifies SIM brands sharing a host network; EF_AD disambiguates
  # two- and three-digit MNCs. Neither the IMSI nor raw SIM files leave here.
  def read(query, apn \\ "", provider_id \\ nil) do
    resolve(
      query.("AT+CIMI"),
      query.("AT+CRSM=176,28486,0,0,17"),
      query.("AT+CRSM=176,28589,0,0,4"),
      apn,
      provider_id
    )
  end

  @doc false
  def resolve(imsi_reply, spn_reply, ad_reply, apn \\ "", provider_id \\ nil) do
    imsi = imsi(imsi_reply)
    length = mnc_length(ad_reply)
    candidates = candidates(imsi, length)

    named =
      if provider_id == nil, do: Enum.filter(candidates, &named?(&1, spn(spn_reply))), else: []

    # A SIM brand can guide Automatic without hiding other home-network plans:
    # some virtual operators leave their host network's generic SPN on the SIM.
    options = candidates |> Enum.filter(&usable?/1) |> options()
    candidates = if named == [], do: candidates, else: named
    relevant = if apn == "", do: candidates, else: Enum.filter(candidates, &(&1["apn"] == apn))
    matching = Enum.filter(relevant, &usable?/1)

    networks =
      relevant
      |> Enum.flat_map(& &1["networks"])
      |> Enum.filter(&network?(&1, imsi, length))
      |> Enum.uniq()

    selected = select(provider_id, relevant, networks, matching, apn)

    %{
      apn: if(apn == "" and selected != nil, do: selected["apn"], else: apn),
      credentials: if(selected, do: credentials(selected)),
      provider:
        if(selected,
          do: %{
            name: if(provider_id, do: selected["name"], else: provider_name(matching)),
            apn: selected["apn"]
          }
        ),
      options: options,
      error: selection_error(provider_id, selected)
    }
  end

  def option(id) do
    case Enum.find(@profiles, &(&1["id"] == id)) do
      nil -> nil
      profile -> Map.take(profile, ["id", "name", "plan", "apn"])
    end
  end

  defp select(nil, relevant, networks, matching, apn) do
    if selectable?(relevant, networks, matching, apn), do: unique_settings(matching)
  end

  defp select(id, _, _, matching, _),
    do: matching |> Enum.filter(&(&1["id"] == id)) |> unique_settings()

  defp selection_error(nil, _), do: nil

  defp selection_error(_, nil),
    do: %{
      code: "cellular_provider_unavailable",
      message:
        "The selected carrier profile does not match this SIM or is unavailable. Choose Automatic or another carrier in Connection settings."
    }

  defp selection_error(_, _), do: nil

  defp selectable?(candidates, [_], matching, apn) do
    Enum.all?(candidates, &usable?/1) and
      (apn != "" or Enum.any?(matching, &(&1["gid1"] == [])))
  end

  defp selectable?(_, _, _, _), do: false

  defp candidates(nil, _), do: []

  defp candidates(imsi, length),
    do:
      Enum.filter(@profiles, fn profile ->
        Enum.any?(profile["networks"], &network?(&1, imsi, length))
      end)

  defp network?(_, nil, _), do: false
  defp network?(network, imsi, nil), do: String.starts_with?(imsi, network)

  defp network?(network, imsi, length),
    do: byte_size(network) == 3 + length and String.starts_with?(imsi, network)

  defp named?(_, nil), do: false
  defp named?(profile, name), do: Enum.any?(profile["names"], &(normalize(&1) == normalize(name)))
  defp normalize(name), do: name |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]/u, "")

  defp usable?(profile) do
    profile["authentication"] != "chap" and
      ((profile["username"] == "" and profile["password"] == "" and
          profile["authentication"] == "") or
         Authentication.valid?(profile["apn"], profile["username"], profile["password"]))
  end

  defp credentials(%{"username" => "", "password" => ""}), do: nil

  defp credentials(profile),
    do: %{apn: profile["apn"], username: profile["username"], password: profile["password"]}

  defp unique_settings([]), do: nil

  defp unique_settings(profiles) do
    case Enum.uniq_by(profiles, &{&1["apn"], credentials(&1)}) do
      [profile] -> profile
      _ -> nil
    end
  end

  defp provider_name(profiles) do
    case profiles |> Enum.map(& &1["name"]) |> Enum.uniq() do
      [name] -> name
      _ -> "Carrier settings"
    end
  end

  defp options(profiles) do
    profiles
    |> Enum.group_by(& &1["id"])
    |> Enum.flat_map(fn {_, matching} ->
      case unique_settings(matching) do
        nil -> []
        profile -> [Map.take(profile, ["id", "name", "plan", "apn"])]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["name"], &1["plan"], &1["apn"]})
  end

  defp imsi({:ok, lines}), do: Enum.find(lines, &Regex.match?(~r/\A[0-9]{14,15}\z/, &1))
  defp imsi(_), do: nil

  defp sim_file({:ok, lines}) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/\A\+CRSM:\s*144,\s*0,\s*"([0-9a-fA-F]+)"\s*\z/, line) do
        [_, hex] ->
          decode_file(hex)

        _ ->
          nil
      end
    end)
  end

  defp sim_file(_), do: nil

  defp decode_file(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  defp spn(reply) do
    case sim_file(reply) do
      <<_display, bytes::binary>> ->
        name =
          bytes |> :binary.bin_to_list() |> Enum.take_while(&(&1 != 255)) |> :binary.list_to_bin()

        if Regex.match?(~r/\A[\x20-\x7E]+\z/, name) and String.trim(name) != "",
          do: String.trim(name)

      _ ->
        nil
    end
  end

  defp mnc_length(reply) do
    case sim_file(reply) do
      <<_, _, _, length>> when length in [2, 3] -> length
      _ -> nil
    end
  end
end
