defmodule NervesGateWeb.AppReleasePageTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias NervesGateWeb.AppsLive

  defp socket do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{},
      apps: [],
      releases: nil,
      review: nil,
      busy: nil,
      outcome: nil,
      unknown?: false
    )
  end

  test "review renders exact identity and effects without exposing its private token" do
    release = %{
      "app" => "tailnet_subrouter",
      "version" => "1.1.0",
      "size" => 1234,
      "sha256" => String.duplicate("a", 64),
      "source_revision" => String.duplicate("b", 40),
      "sdk" => "~> 0.2.0-dev",
      "otp" => "29",
      "elixir" => "1.20.4",
      "platform" => [["phoenix_live_view", "1.2.13"]]
    }

    review = %{
      token: make_ref(),
      action: :upgrade,
      selection: %{active_version: "1.0.0", running?: false},
      release: release
    }

    {:noreply, reviewed} =
      AppsLive.handle_async(
        :app_operation,
        {:ok, {:ok, review}},
        Phoenix.Component.assign(socket(), :busy, :review)
      )

    html = render_component(&AppsLive.render/1, Map.put(reviewed.assigns, :apps, []))
    assert html =~ "Confirm upgrade"
    assert html =~ "1.0.0"
    assert html =~ release["sha256"]
    assert html =~ "starts the new version"
    assert html =~ "phoenix_live_view"
    refute html =~ "#Reference"
  end

  test "unknown effects stay unresolved across catalog refresh and require explicit state inspection" do
    {:noreply, interrupted} =
      AppsLive.handle_async(
        :app_operation,
        {:exit, :timeout},
        Phoenix.Component.assign(socket(), :busy, :install)
      )

    assert interrupted.assigns.unknown?
    assert interrupted.assigns.outcome =~ "No command will be retried"

    assert {:noreply, ^interrupted} =
             AppsLive.handle_event("start-app", %{"app" => "tailnet_subrouter"}, interrupted)

    {:noreply, catalog} =
      AppsLive.handle_async(
        :app_operation,
        {:ok, {:ok, []}},
        Phoenix.Component.assign(interrupted, :busy, :catalog)
      )

    assert catalog.assigns.unknown?

    {:noreply, inspected} =
      AppsLive.handle_async(
        :app_operation,
        {:ok, {:ok, []}},
        Phoenix.Component.assign(catalog, :busy, :state)
      )

    refute inspected.assigns.unknown?
  end

  test "initial page never fetches releases or submits a package command" do
    html = render_component(&AppsLive.render/1, socket().assigns)
    assert html =~ "Check GitHub releases"
    assert html =~ "Nothing downloads until requested"
    refute html =~ "Confirm install"
    refute html =~ "Confirm upgrade"
  end
end
