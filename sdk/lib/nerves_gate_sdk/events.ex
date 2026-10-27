defmodule NervesGateSDK.Events do
  @moduledoc "Process-owned subscriptions to public observations. Subscribe before querying."
  alias NervesGateSDK.Backend

  defmodule Event do
    @moduledoc "A public event delivered directly to the subscribing process."
    @enforce_keys [:topic, :value]
    defstruct [:topic, :value]
    @type t :: %__MODULE__{topic: :system | :network | :storage, value: term()}
  end

  @topics [:system, :network, :storage]

  @spec subscribe(atom()) :: :ok | {:error, term()}
  def subscribe(topic) when topic in @topics, do: Backend.call(:events_subscribe, [topic])
  def subscribe(_), do: {:error, :invalid_topic}

  @spec unsubscribe(atom()) :: :ok | {:error, term()}
  def unsubscribe(topic) when topic in @topics, do: Backend.call(:events_unsubscribe, [topic])
  def unsubscribe(_), do: {:error, :invalid_topic}
end
