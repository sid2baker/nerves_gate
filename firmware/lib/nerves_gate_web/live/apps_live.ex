defmodule NervesGateWeb.AppsLive do
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_apps, 2_000)

    {:ok,
     assign(socket,
       apps: applications(),
       releases: nil,
       review: nil,
       busy: nil,
       outcome: nil,
       unknown?: false
     )}
  end

  def handle_info(:refresh_apps, socket) do
    Process.send_after(self(), :refresh_apps, 2_000)
    {:noreply, assign(socket, :apps, applications())}
  end

  def handle_event(_, _, %{assigns: %{busy: busy}} = socket) when not is_nil(busy),
    do: {:noreply, socket}

  def handle_event("check-releases", _, socket),
    do: run(socket, :catalog, &NervesGate.Apps.available_releases/0)

  def handle_event("refresh-state", _, socket), do: run(socket, :state, &NervesGate.Apps.list/0)
  def handle_event("cancel-review", _, socket), do: {:noreply, assign(socket, :review, nil)}

  def handle_event("review-release", %{"app" => app, "version" => version}, socket),
    do:
      run(assign(socket, :review, nil), :review, fn ->
        NervesGate.Apps.review_release(app, version)
      end)

  def handle_event("confirm-release", _, %{assigns: %{review: review, unknown?: false}} = socket)
      when not is_nil(review) do
    run(assign(socket, :review, nil), :install, fn ->
      NervesGate.Apps.install_release(review.token)
    end)
  end

  def handle_event(action, %{"app" => app}, %{assigns: %{unknown?: false}} = socket)
      when action in ["start-app", "stop-app"] do
    operation = if action == "start-app", do: :start, else: :stop
    run(socket, operation, fn -> apply(NervesGate.Apps, operation, [app]) end)
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp run(socket, operation, fun) do
    {:noreply,
     socket |> assign(busy: operation, outcome: nil) |> start_async(:app_operation, fun)}
  end

  def handle_async(:app_operation, {:ok, result}, socket) do
    operation = socket.assigns.busy
    socket = assign(socket, busy: nil, apps: applications())

    socket =
      case {operation, result} do
        {:catalog, {:ok, releases}} ->
          assign(socket, :releases, releases)

        {:review, {:ok, review}} ->
          assign(socket, :review, review)

        {:state, {:ok, apps}} ->
          assign(socket,
            apps: apps,
            unknown?: false,
            outcome: "Current application state refreshed. Inspect it before another command."
          )

        {_, :ok} ->
          assign(socket, :outcome, "Application command completed.")

        {:install, {:ok, _}} ->
          assign(socket, :outcome, "Installed stopped. Choose Start when ready.")

        {_, {:error, reason}} ->
          assign(socket,
            outcome: error(reason),
            unknown?: socket.assigns.unknown? or uncertain?(reason)
          )
      end

    {:noreply, socket}
  end

  def handle_async(:app_operation, {:exit, _}, socket) do
    effect? = socket.assigns.busy in [:install, :start, :stop]

    {:noreply,
     assign(socket,
       busy: nil,
       apps: applications(),
       unknown?: socket.assigns.unknown? or effect?,
       outcome:
         "Request interrupted. Inspect current state before continuing. No command will be retried automatically."
     )}
  end

  def render(assigns) do
    ~H"""
    <.page_header
      title="Applications"
      description="Install first-party GitHub releases and open application-owned pages."
    />
    <.notice :if={@apps == :unavailable} tone="warning">
      Application management is unavailable.
    </.notice>
    <.notice :if={@outcome} tone="neutral" id="app-operation-result">{@outcome}</.notice>
    <.notice :if={@unknown?} tone="warning">
      A command outcome is unresolved. Refresh and inspect state before another command; refreshing does not cancel or replay it.
    </.notice>
    <p :if={@busy} role="status">
      Working… Downloads and lifecycle operations may take several minutes. Do not repeat the request.
    </p>
    <button class="ui-button ui-button--secondary" phx-click="refresh-state" disabled={@busy != nil}>Refresh application state</button>
    <p :if={@apps == []} class="ui-help">No applications installed.</p>
    <section :if={is_list(@apps)} class="ui-stack" id="installed-apps">
      <article :for={app <- @apps} class="ui-panel">
        <div class="ui-panel-body">
          <h2>{app.app}</h2>
          <p>{app.active_version} · {if app.running?, do: "Running", else: "Stopped"}</p>
          <p :if={app.error} role="alert">{error(app.error)}</p>
          <div class="ui-actions">
            <a
              :if={app.ui? and app.running?}
              href={"/apps/#{app.app}"}
              class="ui-button ui-button--primary"
            >Open application</a>
            <button
              :if={!app.running?}
              class="ui-button ui-button--secondary"
              phx-click="start-app"
              phx-value-app={app.app}
              disabled={@busy != nil or @unknown?}
            >Start</button>
            <button
              :if={app.running? or app.operation != nil or app.error != nil}
              class="ui-button ui-button--secondary"
              phx-click="stop-app"
              phx-value-app={app.app}
              disabled={@busy != nil or @unknown?}
            >Stop</button>
          </div>
          <p :if={!app.ui?} class="ui-help">
            No application page available. The app must be running and supply a UI.
          </p>
        </div>
      </article>
    </section>
    <section class="ui-panel" id="github-app-releases">
      <div class="ui-panel-body">
        <h2>First-party releases</h2>
        <p class="ui-help">
          Public releases from sid2baker/nerves_gate. Nothing downloads until requested. New installs remain stopped; upgrades explicitly stop/start the application. App startup may perform app-owned actions.
        </p>
        <button
          class="ui-button ui-button--secondary"
          phx-click="check-releases"
          disabled={@busy != nil}
        >Check GitHub releases</button>
        <p :if={@releases == []}>
          No first-party app releases are published in the current GitHub release listing.
        </p>
        <article :for={release <- @releases || []}>
          <h3>{release.name} · {release.version}{if release.prerelease?, do: " (prerelease)"}</h3>
          <button
            class="ui-button ui-button--primary"
            phx-click="review-release"
            phx-value-app={release.app}
            phx-value-version={release.version}
            disabled={@busy != nil or @unknown? or @apps == :unavailable}
          >Review install / upgrade</button>
        </article>
      </div>
    </section>
    <section :if={@review} class="ui-panel" id="app-release-review">
      <div class="ui-panel-body">
        <h2>Review {if @review.action == :upgrade, do: "upgrade", else: "installation"}</h2>
        <p>{@review.release["app"]} · {@review.release["version"]}</p>
        <p :if={@review.selection}>
          Current: {@review.selection.active_version} · {if @review.selection.running?,
            do: "running",
            else: "stopped"}
        </p>
        <p>Archive size: {@review.release["size"]} bytes</p>
        <p>SHA-256: <code>{@review.release["sha256"]}</code></p>
        <p>Source revision: <code>{@review.release["source_revision"]}</code></p>
        <p>Required SDK: {@review.release["sdk"]}</p>
        <p>OTP {@review.release["otp"]} · Elixir {@review.release["elixir"]}</p>
        <p :for={[name, version] <- @review.release["platform"]}>{name}: {version}</p>
        <p :if={@review.action == :install}>Installs stopped. Start separately when ready.</p>
        <p :if={@review.action == :upgrade}>
          This stops any running version and starts the new version. Failure restores the previous running/stopped selection only if cleanup and rollback are confirmed.
        </p>
        <p class="ui-help">
          One-use review expires in ten minutes. Storage, selection, compatibility and archive integrity are checked again. No automatic retry or update.
        </p>
        <div class="ui-actions">
          <button
            class="ui-button ui-button--primary"
            phx-click="confirm-release"
            disabled={@busy != nil or @unknown?}
          >Confirm {if @review.action == :upgrade, do: "upgrade", else: "install"}</button>
          <button
            class="ui-button ui-button--secondary"
            phx-click="cancel-review"
            disabled={@busy != nil}
          >Cancel</button>
        </div>
      </div>
    </section>
    """
  end

  defp applications do
    case NervesGate.Apps.list() do
      {:ok, apps} -> apps
      _ -> :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  defp uncertain?(reason)
       when reason in [:operation_timeout, :lifecycle_failed, :metadata_commit_unknown], do: true

  defp uncertain?({:rollback_failed, _, _}), do: true
  defp uncertain?({:metadata_write, :metadata_commit_unknown}), do: true
  defp uncertain?(_), do: false

  defp error(:release_not_published),
    do: "This app release has not been published on GitHub. No package was installed."

  defp error(:release_rate_limited),
    do: "GitHub denied or rate-limited this request. Try checking later; no automatic retry."

  defp error(:release_fetch_failed),
    do: "Release download failed or exceeded its limits. No automatic retry."

  defp error(:release_review_expired),
    do: "Review expired or was already used. Refresh state and request a new review."

  defp error(:release_review_changed),
    do: "Storage or application selection changed. Request a new review."

  defp error(:incompatible_platform_dependency),
    do: "This release requires different platform libraries. Update compatible firmware first."

  defp error(:incompatible_release_target), do: "This release does not support this target."

  defp error(:incompatible_release_runtime),
    do: "This release requires a different OTP or Elixir runtime."

  defp error(:incompatible_sdk),
    do: "This release requires a different SDK. Update compatible firmware first."

  defp error({:rolled_back, _}), do: "Upgrade failed; the previous selection was restored."

  defp error({:rollback_failed, _, _}),
    do:
      "Upgrade and rollback failed. Application management is blocked; inspect the gateway before continuing."

  defp error({:metadata_write, _}),
    do: "Application metadata could not be committed. Inspect current state before continuing."

  defp error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp error(_), do: "Application operation failed. Inspect gateway state before continuing."
end
