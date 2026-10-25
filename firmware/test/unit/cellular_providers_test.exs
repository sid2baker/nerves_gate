defmodule NervesGate.Cellular.ProvidersTest do
  use ExUnit.Case, async: true
  alias NervesGate.Cellular.{Authentication, Providers}

  @imsi {:ok, ["262010000000001"]}
  @ad {:ok, [~s(+CRSM: 144,0,"00000002")]}

  test "SIM brand resolves a virtual carrier offline, including public authentication" do
    settings = Providers.resolve(@imsi, spn("congstar"), @ad)
    assert settings.apn == "internet.telekom"
    assert settings.provider == %{name: "Congstar", apn: "internet.telekom"}
    assert Enum.any?(settings.options, &(&1["name"] != "Congstar"))

    assert Authentication.valid?(
             settings.apn,
             settings.credentials.username,
             settings.credentials.password
           )

    public = Map.take(settings, [:provider, :options]) |> inspect()
    refute public =~ "262010000000001"
    refute public =~ "username"
    refute public =~ "password"
  end

  test "an ambiguous home network does not guess the virtual carrier or plan" do
    settings = Providers.resolve(@imsi, {:error, :unsupported}, @ad)
    assert settings.apn == ""
    assert settings.credentials == nil
    assert settings.provider == nil
    assert settings.options != []
    assert Enum.any?(settings.options, &(&1["name"] == "Congstar"))
  end

  test "unknown SIMs and unsupported SIM text fall back without inventing credentials" do
    for identity <- [{:error, :locked}, {:ok, ["OK"]}, {:ok, ["123"]}] do
      settings = Providers.resolve(identity, spn("congstar"), @ad)
      assert settings == %{apn: "", provider: nil, credentials: nil, options: [], error: nil}
    end

    malformed = {:ok, [~s(+CRSM: 144,0,"008063006F006E00670073007400610072")]}
    assert Providers.resolve(@imsi, malformed, @ad).provider == nil
    assert Providers.resolve(@imsi, spn(" "), @ad).provider == nil
  end

  test "manual APNs never borrow credentials from a different APN" do
    settings = Providers.resolve(@imsi, spn("congstar"), @ad, "private.example")
    assert settings.apn == "private.example"
    assert settings.credentials == nil
    assert settings.provider == nil
    assert Providers.resolve(@imsi, spn("congstar"), @ad, "internet.telekom").credentials != nil
  end

  test "an explicit carrier choice preserves credentials when brands share an APN" do
    settings = Providers.resolve(@imsi, {:error, :unsupported}, @ad)
    option = Enum.find(settings.options, &(&1["name"] == "Congstar"))
    chosen = Providers.resolve(@imsi, {:error, :unsupported}, @ad, option["apn"], option["id"])
    assert chosen.provider.name == "Congstar"
    assert chosen.credentials != nil
    assert chosen.error == nil
    assert Providers.option(option["id"]) == option

    invalid =
      Providers.resolve(@imsi, spn("congstar"), @ad, option["apn"], String.duplicate("0", 64))

    assert invalid.credentials == nil
    assert invalid.error.code == "cellular_provider_unavailable"
  end

  defp spn(name), do: {:ok, [~s(+CRSM: 144,0,"00#{Base.encode16(name)}FFFFFFFF")]}
end
