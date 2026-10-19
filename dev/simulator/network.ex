defmodule NervesGate.Simulator.Network do
  @moduledoc """
  The owned bench's real Ethernet switch. QEMU supplies the network protocols.

  Configuration is a partial map; omitted values stay unchanged:

      %{internet: :lan2, cables: %{lan1: false}, uplink: %{delay_ms: 200, loss: :alternate}}

  Loss is :none, :alternate or :all. Management is not configurable.
  """
  use GenServer, restart: :temporary
  alias __MODULE__.Ethernet

  @ports [:lan1, :lan2, :internet, :management, :control]
  @max_bytes 4 * 1024 * 1024
  @max_frames 4096
  @defaults %{
    internet: :lan1,
    cables: %{lan1: true, lan2: true},
    uplink: %{delay_ms: 0, loss: :none}
  }

  def defaults, do: @defaults
  def baseline, do: connections(:lan1)

  def connections(internet),
    do: Map.new([:lan1, :lan2], &{&1, if(&1 == internet, do: :internet, else: :equipment)})

  def start_link(dir), do: GenServer.start_link(__MODULE__, dir)
  def snapshot(server), do: GenServer.call(server, :snapshot)
  def configure(server, patch), do: GenServer.call(server, {:configure, patch})
  def attach(server), do: GenServer.call(server, :attach, 15_000)
  def detach(server), do: GenServer.call(server, :detach)
  def release(server), do: GenServer.call(server, :release)

  # A fixed graph: only frame forwarding changes, never a realized NIC's netdev.
  def arguments(dir, address, forwards, usb) do
    streams =
      Enum.flat_map(@ports, fn port ->
        [
          "-netdev",
          "stream,id=#{port},server=on,addr.type=unix,addr.path=#{socket_path(dir, port)}"
        ]
      end)

    nics =
      Enum.flat_map([lan1: "56", lan2: "57", management: "58"], fn {port, suffix} ->
        ["-device", "virtio-net-pci,netdev=#{port},id=#{port}-nic,mac=52:54:00:12:34:#{suffix}"]
      end)

    internet = router(0, :internet, "user,id=wan,net=10.0.2.0/24,ipv6=off", "wan")

    management =
      "user,id=mgmt,net=192.168.77.0/24,host=192.168.77.1,ipv6=off,restrict=on" <>
        forward(address, forwards.epmd, "192.168.77.2", 4369) <>
        forward(address, forwards.distribution, "192.168.77.2", 9100) <>
        forward("127.0.0.1", forwards.http, "192.168.77.2", 4000) <>
        forward(address, forwards.ssh, "192.168.77.2", 22)

    # VintageNetDirect runs in the guest, including its DHCP server. Libslirp is
    # a statically addressed recovery peer, not a DHCP-client qualification.
    usb = [
      "-netdev",
      "user,id=usb,net=#{usb.network}/24,host=#{usb.peer},ipv6=off,restrict=on" <>
        forward(address, forwards.usb, usb.device, 22),
      "-device",
      "virtio-net-pci,netdev=usb,id=usb-nic,mac=52:54:00:12:34:59"
    ]

    streams ++ nics ++ internet ++ router(1, :control, management, "mgmt") ++ usb
  end

  defp router(id, stream, user, backend) do
    [
      "-netdev",
      user,
      "-netdev",
      "hubport,id=hub#{id}-socket,hubid=#{id},netdev=#{stream}",
      "-netdev",
      "hubport,id=hub#{id}-router,hubid=#{id},netdev=#{backend}"
    ]
  end

  defp forward(host, port, address, target),
    do: ",hostfwd=tcp:#{host}:#{port}-#{address}:#{target}"

  defp socket_path(dir, port),
    do: dir |> Path.join("#{port}.sock") |> Path.relative_to_cwd()

  @impl true
  def init(dir) do
    {:ok,
     %{
       dir: dir,
       config: @defaults,
       sockets: %{},
       held: true,
       queue: :queue.new(),
       bytes: 0,
       timer: nil,
       sequence: 0,
       stats: %{
         forwarded: 0,
         denied: 0,
         rejected: %{lan1: 0, lan2: 0, management: 0},
         dropped: 0,
         candidates: 0,
         overflow: 0,
         discarded: 0,
         delayed: 0,
         min_delay_ms: nil
       }
     }}
  end

  # Raw management frames can contain distribution credentials and private UI
  # data. Neither OTP crash reports nor sys.get_status may expose packet buffers.
  @impl true
  def format_status(%{state: state} = status) do
    status
    |> Map.replace(:state, %{
      config: state.config,
      connected: Map.keys(state.sockets),
      stats: state.stats
    })
    |> Map.replace(:message, :redacted)
    |> Map.replace(:reason, :network_failure)
    |> Map.replace(:log, [])
  end

  @impl true
  def handle_call(:snapshot, _, state) do
    view = %{
      config: state.config,
      connected: Map.keys(state.sockets) |> Enum.sort(),
      ready: map_size(state.sockets) == length(@ports) and not state.held,
      stats: state.stats
    }

    {:reply, view, state}
  end

  def handle_call({:configure, patch}, _, state) do
    case merge(state.config, patch) do
      {:ok, config} ->
        changed = config.internet != state.config.internet or config.cables != state.config.cables
        state = if config != state.config, do: discard(state), else: state

        stats =
          if config.uplink.delay_ms != state.config.uplink.delay_ms,
            do: %{state.stats | delayed: 0, min_delay_ms: nil},
            else: state.stats

        sequence = if config.uplink.loss != state.config.uplink.loss, do: 0, else: state.sequence

        {:reply, {:ok, state.config, config},
         %{state | config: config, held: state.held or changed, stats: stats, sequence: sequence}}

      :error ->
        {:reply, {:error, :invalid_network}, state}
    end
  end

  def handle_call(:attach, _, %{sockets: sockets} = state) when map_size(sockets) == 0 do
    sockets =
      Map.new(@ports, fn port ->
        {:ok, socket} =
          :gen_tcp.connect(
            {:local, socket_path(state.dir, port)},
            0,
            [
              :binary,
              packet: 4,
              packet_size: 65_536,
              active: :once,
              send_timeout: 1000,
              send_timeout_close: true,
              buffer: 65_536
            ],
            2000
          )

        {port, socket}
      end)

    {:reply, :ok, %{state | sockets: sockets, held: true}}
  end

  def handle_call(:detach, _, state) do
    for socket <- Map.values(state.sockets), do: :gen_tcp.close(socket)
    {:reply, :ok, %{discard(state) | sockets: %{}, held: true}}
  end

  def handle_call(:release, _, state) when map_size(state.sockets) == length(@ports),
    do: {:reply, :ok, %{state | held: false}}

  def handle_call(:release, _, state), do: {:reply, {:error, :disconnected}, state}

  @impl true
  def handle_info({:tcp, socket, frame}, state) do
    case Enum.find(state.sockets, fn {_, peer} -> peer == socket end) do
      {port, _} ->
        state = route(port, frame, state)
        :ok = :inet.setopts(socket, active: :once)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    disconnected(socket, state)
  end

  def handle_info({:tcp_error, socket, _}, state), do: disconnected(socket, state)

  def handle_info({:flush, token}, %{timer: {_, token}} = state),
    do: {:noreply, flush(%{state | timer: nil})}

  def handle_info(_, state), do: {:noreply, state}

  defp disconnected(socket, state) do
    if socket in Map.values(state.sockets),
      do: {:stop, :network_disconnected, state},
      else: {:noreply, state}
  end

  # Management never passes through the LAN fault queue.
  defp route(:control, frame, state), do: deliver(state, :management, frame)

  defp route(:management, frame, state),
    do: admit(state, :management, :control, frame, :management)

  defp route(_, _, %{held: true} = state), do: count(state, :discarded)

  defp route(:internet, frame, state) do
    port = state.config.internet
    if state.config.cables[port], do: deliver(state, port, frame), else: count(state, :discarded)
  end

  defp route(port, frame, state) when port in [:lan1, :lan2] do
    cond do
      not state.config.cables[port] -> count(state, :discarded)
      state.config.internet == port -> admit(state, port, :internet, frame, :internet)
      true -> equipment(state, port, frame)
    end
  end

  defp equipment(state, port, frame) do
    state =
      case frame do
        <<_::96, 2048::16, _::binary>> -> reject(state, port)
        _ -> state
      end

    Enum.reduce([:lan1, :lan2] -- [port, state.config.internet], state, fn peer, acc ->
      if state.config.cables[peer] do
        deliver(acc, peer, frame)
      else
        acc
      end
    end)
  end

  defp admit(state, port, target, frame, network) do
    case Ethernet.classify(frame, network) do
      :local -> deliver(state, target, frame)
      :uplink -> impair(state, frame)
      :deny -> reject(state, port)
    end
  end

  defp reject(state, port) do
    state |> count(:denied) |> update_in([:stats, :rejected, port], &(&1 + 1))
  end

  defp impair(state, frame) do
    %{loss: loss, delay_ms: delay} = state.config.uplink
    drop? = loss == :all or (loss == :alternate and rem(state.sequence, 2) == 0)
    state = %{count(state, :candidates) | sequence: state.sequence + 1}

    cond do
      drop? ->
        count(state, :dropped)

      delay == 0 ->
        deliver(state, :internet, frame)

      state.bytes + byte_size(frame) > @max_bytes or :queue.len(state.queue) >= @max_frames ->
        count(state, :overflow)

      true ->
        now = System.monotonic_time(:millisecond)
        queue = :queue.in({now + delay, now, frame}, state.queue)
        schedule(%{state | queue: queue, bytes: state.bytes + byte_size(frame)})
    end
  end

  defp flush(state) do
    now = System.monotonic_time(:millisecond)

    case :queue.out(state.queue) do
      {{:value, {due, entered, frame}}, rest} when due <= now ->
        elapsed = now - entered
        minimum = min(state.stats.min_delay_ms || elapsed, elapsed)
        state = deliver(state, :internet, frame)

        state = %{
          state
          | queue: rest,
            bytes: state.bytes - byte_size(frame),
            stats: %{state.stats | delayed: state.stats.delayed + 1, min_delay_ms: minimum}
        }

        flush(state)

      _ ->
        schedule(state)
    end
  end

  defp schedule(%{timer: nil} = state) do
    case :queue.peek(state.queue) do
      {:value, {due, _, _}} ->
        token = make_ref()

        timer =
          Process.send_after(
            self(),
            {:flush, token},
            max(due - System.monotonic_time(:millisecond), 0)
          )

        %{state | timer: {timer, token}}

      :empty ->
        state
    end
  end

  defp schedule(state), do: state

  defp discard(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    stats = %{state.stats | discarded: state.stats.discarded + :queue.len(state.queue)}
    %{state | queue: :queue.new(), bytes: 0, timer: nil, stats: stats}
  end

  defp deliver(state, port, frame) do
    :ok = :gen_tcp.send(Map.fetch!(state.sockets, port), frame)
    count(state, :forwarded)
  end

  defp count(state, key), do: update_in(state, [:stats, key], &(&1 + 1))

  defp merge(config, patch) when is_map(patch) do
    with true <- Enum.all?(Map.keys(patch), &(&1 in [:internet, :cables, :uplink])),
         cables when is_map(cables) <- Map.get(patch, :cables, %{}),
         uplink when is_map(uplink) <- Map.get(patch, :uplink, %{}),
         true <-
           Enum.all?(cables, fn {key, value} -> key in [:lan1, :lan2] and is_boolean(value) end),
         true <- Enum.all?(Map.keys(uplink), &(&1 in [:delay_ms, :loss])) do
      next = %{
        internet: Map.get(patch, :internet, config.internet),
        cables: Map.merge(config.cables, cables),
        uplink: Map.merge(config.uplink, uplink)
      }

      if next.internet in [:lan1, :lan2, :off] and next.uplink.loss in [:none, :alternate, :all] and
           is_integer(next.uplink.delay_ms) and next.uplink.delay_ms in 0..5000,
         do: {:ok, next},
         else: :error
    else
      _ -> :error
    end
  end

  defp merge(_, _), do: :error
end
