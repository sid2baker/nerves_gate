defmodule NervesGate.Device do
  @moduledoc "Owns the editable device profile stored in `/data/device.json`."

  use GenServer

  alias NervesGate.Identity
  alias NervesGate.Store

  @history_limit 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec get(GenServer.server()) :: map()
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @spec rename(String.t(), map(), GenServer.server()) :: :ok | {:error, :invalid_name | term()}
  def rename(name, actor, server \\ __MODULE__) do
    GenServer.call(server, {:rename, name, public_actor(actor)})
  end

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())
    path = Path.join(root, "device.json")
    profile = load(path)
    unless File.exists?(path), do: Store.write_json(path, profile)
    {:ok, %{path: path, profile: profile}}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.profile, state}

  def handle_call({:rename, name, actor}, _from, state) do
    with {:ok, name} <- valid_name(name),
         profile <- changed_profile(state.profile, name, actor),
         :ok <- Store.write_json(state.path, profile) do
      Phoenix.PubSub.local_broadcast(NervesGate.PubSub, "device", {:device_changed, profile})
      {:reply, :ok, %{state | profile: profile}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp load(path) do
    validator = fn
      %{"version" => 1, "name" => name} = profile when is_binary(name) ->
        {:ok, Map.merge(default_profile(), profile)}

      _profile ->
        {:error, :invalid_device_profile}
    end

    case Store.read_json(path, validator, default_profile()) do
      {:ok, profile} -> profile
      {:error, _reason} -> default_profile()
    end
  end

  defp default_profile do
    %{
      "version" => 1,
      "name" => Identity.get().hostname,
      "revision" => 0,
      "updated_at" => nil,
      "updated_by" => nil,
      "history" => [],
      "documents" => []
    }
  end

  defp changed_profile(%{"name" => name} = profile, name, _actor), do: profile

  defp changed_profile(profile, name, actor) do
    changed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    revision = Map.get(profile, "revision", 0) + 1

    change = %{
      "revision" => revision,
      "changed_at" => changed_at,
      "changed_by" => actor,
      "field" => "name",
      "from" => profile["name"],
      "to" => name
    }

    profile
    |> Map.put("name", name)
    |> Map.put("revision", revision)
    |> Map.put("updated_at", changed_at)
    |> Map.put("updated_by", actor)
    |> Map.update!("history", fn history -> Enum.take([change | history], @history_limit) end)
  end

  defp valid_name(name) when is_binary(name) do
    name = String.trim(name)

    if byte_size(name) in 1..80 and String.printable?(name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp valid_name(_name), do: {:error, :invalid_name}

  defp public_actor(%{name: name} = actor) do
    %{"name" => name || "unknown", "ip" => Map.get(actor, :ip)}
  end

  defp public_actor(%{"name" => name} = actor) do
    %{"name" => name || "unknown", "ip" => Map.get(actor, "ip")}
  end

  defp public_actor(_actor), do: %{"name" => "unknown", "ip" => nil}
end
