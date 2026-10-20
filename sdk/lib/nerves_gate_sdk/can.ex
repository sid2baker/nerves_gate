defmodule NervesGateSDK.CAN do
  @moduledoc "CAN frames and process-owned receive subscriptions. No interface configuration."
  alias NervesGateSDK.Backend

  defmodule Frame do
    @moduledoc "A classic CAN frame. Data is at most eight bytes; FD frames are not supported."
    @enforce_keys [:id, :data]
    defstruct [:id, :data, extended?: false, remote?: false]

    @type t :: %__MODULE__{
            id: non_neg_integer(),
            data: binary(),
            extended?: boolean(),
            remote?: boolean()
          }

    @doc false
    def valid?(%__MODULE__{id: id, data: data, extended?: extended, remote?: remote})
        when is_integer(id) and id >= 0 and is_binary(data) and byte_size(data) <= 8 and
               is_boolean(extended) and is_boolean(remote),
        do: id <= if(extended, do: 0x1FFFFFFF, else: 0x7FF)

    def valid?(_), do: false
  end

  defmodule Interface do
    @moduledoc "CAN availability. Configuration remains platform-owned."
    @enforce_keys [:id, :state]
    defstruct [:id, :state, :bitrate, listen_only?: true]

    @type t :: %__MODULE__{
            id: String.t(),
            state: :up | :down | :unavailable,
            bitrate: pos_integer() | nil,
            listen_only?: boolean()
          }
  end

  @spec interfaces() :: {:ok, [Interface.t()]} | {:error, term()}
  def interfaces, do: Backend.call(:can_interfaces, [])

  @spec send(String.t(), Frame.t()) :: :ok | {:error, term()}
  def send(interface, frame) when is_binary(interface) do
    if Frame.valid?(frame),
      do: Backend.call(:can_send, [interface, frame]),
      else: {:error, :invalid_frame}
  end

  def send(_, _), do: {:error, :invalid_interface}

  @doc "Receives Events.Event messages with topic `{:can, interface}` and a Frame value."
  def subscribe(interface) when is_binary(interface),
    do: Backend.call(:can_subscribe, [interface])

  def subscribe(_), do: {:error, :invalid_interface}

  def unsubscribe(interface) when is_binary(interface),
    do: Backend.call(:can_unsubscribe, [interface])

  def unsubscribe(_), do: {:error, :invalid_interface}
end
