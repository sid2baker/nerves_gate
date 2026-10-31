defmodule NervesGateWeb.StorageLive do
  use Phoenix.LiveView, log: false
  import NervesGateWeb.CoreComponents

  on_mount({NervesGateWeb.Observations, :status})

  def mount(_, _, socket), do: {:ok, assign(socket, format_card: nil)}

  def handle_event("use", %{"card" => id}, socket),
    do: command(socket, NervesGate.Storage.setup(:use, id))

  def handle_event("skip", _, socket), do: command(socket, NervesGate.Storage.setup(:skip))

  def handle_event("review-format", %{"card" => id}, socket),
    do: {:noreply, assign(clear_flash(socket), :format_card, id)}

  def handle_event("cancel-format", _, socket),
    do: {:noreply, assign(socket, :format_card, nil)}

  def handle_event("format", %{"erase" => "yes"}, %{assigns: %{format_card: id}} = socket)
      when is_binary(id),
      do: command(socket, NervesGate.Storage.setup(:format, id, :erase_all_data))

  def handle_event("format", _, socket),
    do:
      {:noreply, put_flash(socket, :error, "Confirm that all data on this card will be erased.")}

  defp command(socket, result) do
    socket = assign(clear_flash(socket), :format_card, nil)

    case result do
      :ok ->
        {:noreply,
         put_flash(socket, :info, "Storage choice accepted. Live status below shows the result.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def render(assigns) do
    assigns = assign(assigns, :storage, assigns.projection.storage)

    ~H"""
    <.back_link navigate="/settings">Settings</.back_link>
    <.page_header
      eyebrow="Commissioning · optional"
      title="Plugin storage"
      description="Use an SD card for development plugins and their data, or continue without it."
    />
    <.panel title="SD card" icon="display" id="storage-setup">
      <.notice :if={!@storage.available} tone="warning">Storage service is unavailable.</.notice>
      <p id="storage-state">{label(@storage)}</p>
      <p :if={@storage.present} class="ui-help" id="storage-filesystem">
        Detected filesystem: {@storage.filesystem}. Using a prepared card preserves its plugins and data.
      </p>
      <p :if={!@storage.present} class="ui-help">
        Insert an SD card to set it up. No card is needed for networking or gateway administration.
      </p>
      <.notice :if={@storage.error} tone="warning" role="alert" id="storage-error">
        {@storage.error.message}
      </.notice>
      <.notice :if={@storage.operation} tone="neutral" role="status" id="storage-progress">
        {if @storage.operation == :format,
          do: "Formatting and mounting the card…",
          else: "Mounting the card…"} Do not remove the card or interrupt power.
      </.notice>
      <div class="ui-actions">
        <.button
          :if={@storage.present && !@storage.ready && @storage.filesystem == "ext4"}
          id="storage-use"
          phx-click="use"
          phx-value-card={@storage.card_id}
          disabled={!@storage.available || @storage.operation != nil}
        >Use this card — keep data</.button>
        <.button
          :if={@storage.present}
          id="storage-review-format"
          variant="secondary"
          phx-click="review-format"
          phx-value-card={@storage.card_id}
          disabled={!@storage.available || @storage.operation != nil}
        >Format for plugins…</.button>
        <.button
          id="storage-skip"
          variant="secondary"
          phx-click="skip"
          disabled={!@storage.available || @storage.operation != nil}
        >Continue without SD storage</.button>
      </div>
      <p class="ui-help">
        You can return here from Settings. Inserting a card never formats it automatically.
      </p>
      <.link
        :if={@storage.ready || @storage.choice == :skip}
        navigate="/"
        class="ui-text-link"
        id="storage-continue"
      >
        Continue to overview →
      </.link>
    </.panel>
    <.panel
      :if={@format_card}
      title="Erase this SD card?"
      icon="display"
      id="storage-format-confirmation"
    >
      <.notice tone="warning">
        All files, plugins and plugin data on the card's plugin partition will be permanently erased.
        Back up anything you need first. This creates ext4 storage; it does not format internal system storage.
      </.notice>
      <p :if={@format_card != @storage.card_id} role="alert">
        The detected card changed. Cancel and review it again.
      </p>
      <form phx-submit="format" id="storage-format-form">
        <label><input type="checkbox" name="erase" value="yes" required />
        I understand that all card data will be erased.</label>
        <div class="ui-actions">
          <.button
            type="submit"
            id="storage-format"
            disabled={
              @format_card != @storage.card_id || @storage.operation != nil || !@storage.present
            }
          >
            Erase and format SD card
          </.button>
          <.button type="button" variant="secondary" phx-click="cancel-format">Cancel — keep data</.button>
        </div>
      </form>
    </.panel>
    """
  end

  def label(%{ready: true}), do: "Ready for plugins"
  def label(%{operation: :format}), do: "Formatting SD card"
  def label(%{operation: :use}), do: "Setting up SD card"
  def label(%{choice: :skip}), do: "Continuing without SD storage"
  def label(%{present: false}), do: "No readable SD card detected"
  def label(%{filesystem: "ext4"}), do: "Prepared card — ready to set up"
  def label(_), do: "Card needs preparation for plugins"
end
