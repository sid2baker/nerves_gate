defmodule NervesGateWeb.IOLive do
  @moduledoc """
  Observed inputs and desired outputs registered by plugins, with manual control.
  Reads go through `NervesGate.IO.Manual` so `owned?` means manual control; all
  validation stays in `NervesGate.IO`. Freshness depends on elapsed time, not only on
  changes, so the page re-reads once a second. Drafts stay separate from that read.
  """
  use Phoenix.LiveView
  import NervesGateWeb.CoreComponents
  alias NervesGate.IO.Manual

  on_mount({NervesGateWeb.Observations, :status})

  @poll_ms 1_000

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)
    {:ok, socket |> assign(drafts: %{}) |> read()}
  end

  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, read(socket)}
  end

  def handle_event("claim", %{"id" => id}, socket),
    do:
      command(
        socket,
        Manual.claim(id),
        "Manual control taken. No value is set until you set one."
      )

  def handle_event("draft", %{"output" => id, "value" => value}, socket),
    do: {:noreply, update(socket, :drafts, &Map.put(&1, id, value))}

  def handle_event("set", %{"output" => id, "value" => text}, socket) do
    with %{definition: definition} <- output(socket, id),
         {:ok, value} <- parse(definition.type, text) do
      socket = update(socket, :drafts, &Map.delete(&1, id))

      command(
        socket,
        Manual.set(id, value),
        "Desired value stored. The plugin decides how the equipment follows; check its feedback."
      )
    else
      nil -> {:noreply, put_flash(socket, :error, "This output is not defined.")}
      :error -> {:noreply, put_flash(socket, :error, "Enter a #{type_name(output(socket, id))}.")}
    end
  end

  def handle_event("release", %{"id" => id}, socket),
    do:
      command(
        socket,
        Manual.release(id),
        "Manual control released. The target was cleared; the equipment was not reverted or stopped."
      )

  defp command(socket, result, success) do
    socket = clear_flash(socket)

    case result do
      :ok -> {:noreply, socket |> put_flash(:info, success) |> read()}
      {:error, error} -> {:noreply, socket |> put_flash(:error, error.message) |> read()}
    end
  end

  defp read(socket),
    do: assign(socket, io: Manual.status(), now: System.monotonic_time(:millisecond))

  defp output(%{assigns: %{io: %{outputs: outputs}}}, id), do: Enum.find(outputs, &(&1.id == id))
  defp output(_, _), do: nil

  @doc false
  def parse(:boolean, "true"), do: {:ok, true}
  def parse(:boolean, "false"), do: {:ok, false}
  def parse(:integer, text), do: whole(Integer.parse(String.trim(text)))
  def parse(:float, text), do: whole(Float.parse(String.trim(text)))
  def parse(:string, text) when text != "", do: {:ok, text}
  def parse(_, _), do: :error

  defp whole({value, ""}), do: {:ok, value}
  defp whole(_), do: :error

  def render(assigns) do
    ~H"""
    <.page_header
      title="I/O"
      description="Values plugins observe, and targets they keep equipment at."
    />
    <.notice icon="info">
      Setting a desired value only stores the target. The owning plugin decides how and
      whether the equipment follows; check its feedback input. Releasing clears the target
      without reverting or stopping the equipment.
    </.notice>
    <.notice :if={match?({:error, _}, @io)} tone="warning" role="alert" id="io-unavailable">
      I/O is unavailable. {elem(@io, 1).message}
    </.notice>
    <div :if={is_map(@io)} class="ui-stack">
      <.panel title="Inputs" icon="display" id="io-inputs">
        <p :if={@io.inputs == []} class="ui-help">No plugin has registered an input.</p>
        <ul class="ui-io-list">
          <li :for={input <- @io.inputs} id={dom_id("io-input", input.id)}>
            <div>
              <strong>{input.definition.id}</strong>
              <code>{input.id}</code>
              <span class="ui-muted">{describe(input.definition)}</span>
            </div>
            <div class="ui-io-value">
              <strong>{observed(input)}</strong>
              <.status tone={tone(input)}>{state(input)}</.status>
              <span :if={input.observation} class="ui-muted">{age(input.observation, @now)}</span>
            </div>
          </li>
        </ul>
      </.panel>
      <.panel title="Outputs" icon="port" id="io-outputs">
        <p :if={@io.outputs == []} class="ui-help">No plugin has registered an output.</p>
        <ul class="ui-io-list">
          <li :for={output <- @io.outputs} id={dom_id("io-output", output.id)}>
            <div>
              <strong>{output.definition.id}</strong>
              <code>{output.id}</code>
              <span class="ui-muted">{describe(output.definition)}</span>
            </div>
            <div class="ui-io-value">
              <strong>Target: {target(output)}</strong>
              <.status tone={writer_tone(output)}>{writer(output)}</.status>
              <span :if={output.reported} class="ui-muted">
                Feedback: {observed(output.reported)} · {state(output.reported)}
              </span>
            </div>
            <div class="ui-io-controls">
              <.button
                :if={!output.claimed?}
                id={dom_id("io-claim", output.id)}
                variant="secondary"
                phx-click="claim"
                phx-value-id={output.id}
                disabled={!output.available?}
              >Take manual control</.button>
              <.form
                :if={output.owned?}
                for={%{}}
                id={dom_id("io-set", output.id)}
                class="ui-io-controls"
                phx-change="draft"
                phx-submit="set"
              >
                <input type="hidden" name="output" value={output.id} />
                <label for={dom_id("io-value", output.id)}>Desired value</label>
                <select
                  :if={output.definition.type == :boolean}
                  id={dom_id("io-value", output.id)}
                  name="value"
                >
                  <option
                    :for={choice <- ["true", "false"]}
                    value={choice}
                    selected={draft(@drafts, output) == choice}
                  >
                    {choice}
                  </option>
                </select>
                <input
                  :if={output.definition.type != :boolean}
                  type="text"
                  id={dom_id("io-value", output.id)}
                  name="value"
                  value={draft(@drafts, output)}
                  inputmode={if output.definition.type in [:integer, :float], do: "decimal"}
                  autocomplete="off"
                />
                <.button type="submit" disabled={!output.available?}>Set target</.button>
              </.form>
              <.button
                :if={output.owned?}
                id={dom_id("io-release", output.id)}
                variant="quiet"
                phx-click="release"
                phx-value-id={output.id}
              >Release</.button>
            </div>
          </li>
        </ul>
      </.panel>
    </div>
    """
  end

  # Full IDs are lowercase segments joined by dots, so this mapping is unambiguous.
  defp dom_id(prefix, id), do: prefix <> "-" <> String.replace(id, ".", "-")

  defp describe(definition) do
    limits =
      case Map.take(Map.from_struct(definition), [:min, :max]) do
        %{min: nil, max: nil} -> nil
        %{min: min, max: max} -> "#{min || "−∞"} – #{max || "∞"}"
        _ -> nil
      end

    [Atom.to_string(definition.type), definition.unit, limits]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp observed(%{observation: nil}), do: "No value yet"

  defp observed(%{observation: %{quality: :good, value: value}, definition: d}),
    do: format(value, d)

  defp observed(_), do: "—"

  defp target(%{desired: nil}), do: "none"
  defp target(%{desired: value, definition: definition}), do: format(value, definition)

  defp format(value, %{unit: nil}), do: to_string(value)
  defp format(value, %{unit: unit}), do: "#{value} #{unit}"

  defp state(%{available?: false}), do: "Plugin not running"
  defp state(%{observation: nil}), do: "No observation"
  defp state(%{observation: %{quality: :invalid}}), do: "Invalid"
  defp state(%{observation: %{quality: :unknown}}), do: "Unknown"
  defp state(%{stale?: true}), do: "Stale"
  defp state(_), do: "Fresh"

  defp tone(input) do
    case state(input) do
      "Fresh" -> "good"
      "No observation" -> "neutral"
      _ -> "warning"
    end
  end

  defp writer(%{available?: false}), do: "Plugin not running"
  defp writer(%{owned?: true}), do: "Manual control"
  defp writer(%{claimed?: true}), do: "Other writer"
  defp writer(_), do: "Free"

  defp writer_tone(output) do
    case writer(output) do
      "Manual control" -> "busy"
      "Free" -> "neutral"
      _ -> "warning"
    end
  end

  defp age(%{received_at_ms: at}, now) do
    seconds = max(0, div(now - at, 1_000))
    if seconds < 1, do: "just now", else: "#{seconds} s ago"
  end

  defp draft(drafts, %{id: id, desired: desired}),
    do: Map.get_lazy(drafts, id, fn -> if desired == nil, do: "", else: to_string(desired) end)

  defp type_name(%{definition: %{type: :boolean}}), do: "true or false"
  defp type_name(%{definition: %{type: :integer}}), do: "whole number"
  defp type_name(%{definition: %{type: :float}}), do: "number"
  defp type_name(_), do: "non-empty value"
end
