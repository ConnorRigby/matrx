defmodule Matrx.SyncLongPoll do
  use GenServer
  require Logger
  alias Matrx.Presence
  alias Matrx.RoomSupervisor
  alias Matrx.Room

  @api Matrx.API

  @doc """
  Start a sync session
  """
  @spec start_link([{:session, Matrx.Session.t()}], GenServer.options()) :: GenServer.on_start()
  def start_link(args, opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def await_sync(sync_server, timeout \\ 5000) do
    GenServer.call(sync_server, :await_sync, timeout)
  end

  @impl GenServer
  def init(args) do
    server = self()
    session = Keyword.fetch!(args, :session)
    sync = spawn_monitor(fn -> sync_process(server, session) end)
    state = %{session: session, sync: sync, one_time_key_counts: nil, awaiting_sync: nil}
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:await_sync, from, %{awaiting_sync: awaiting_sync} = state) do
    if awaiting_sync, do: GenServer.reply(awaiting_sync, false)
    {:noreply, %{state | awaiting_sync: from}, :hibernate}
  end

  @impl GenServer
  def handle_info({:DOWN, mon, :process, pid, reason}, %{sync: {pid, mon}} = state)
      when reason in [:normal, :killed] do
    {:noreply, %{state | sync: nil}, {:continue, [:sync]}}
  end

  def handle_info({:DOWN, mon, :process, pid, reason}, %{sync: {pid, mon}} = state) do
    Logger.error(%{sync_error: reason})
    {:stop, reason, %{state | sync: nil}}
  end

  def handle_info(%Matrx.API.Sync{} = sync, state) do
    account_data =
      if sync.account_data, do: [{:sync_account_data, sync.account_data.events}], else: []

    presence = if sync.presence, do: [{:sync_presence, sync.presence.events}], else: []
    rooms = if sync.rooms, do: [{:sync_rooms, sync.rooms}], else: []
    to_device = if sync.to_device, do: [{:sync_to_device, sync.to_device.events}], else: []
    device_lists = if sync.device_lists, do: [{:sync_device_lists, sync.device_lists}], else: []

    events = account_data ++ presence ++ rooms ++ to_device ++ device_lists
    if state.awaiting_sync, do: GenServer.reply(state.awaiting_sync, sync)
    state = %{state | one_time_key_counts: sync.device_one_time_keys_count, awaiting_sync: nil}

    if length(events) > 0 do
      {:noreply, state, {:continue, events}}
    else
      Logger.warning("sync has no events")
      {:noreply, state, :hibernate}
    end
  end

  @impl GenServer
  def handle_continue([], state) do
    {:noreply, state, :hibernate}
  end

  def handle_continue([{:sync_account_data, []} | next], state) do
    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_account_data, [_event | rest]} | next], state) do
    {:noreply, state, {:continue, [{:sync_account_data, rest} | next]}}
  end

  def handle_continue([{:sync_presence, []} | next], state) do
    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_presence, [event | rest]} | next], state) do
    :ok = Presence.sync(event)
    {:noreply, state, {:continue, [{:sync_presence, rest} | next]}}
  end

  def handle_continue([{:sync_to_device, []} | next], state) do
    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_to_device, [event | rest]} | next], state) do
    Logger.warning("Unhandled device event: #{inspect(event)}")
    {:noreply, state, {:continue, [{:sync_to_device, rest} | next]}}
  end

  def handle_continue([{:sync_device_lists, device_lists} | next], state) do
    changed =
      if device_lists.changed, do: [{:sync_device_lists_changed, device_lists.changed}], else: []

    left =
      if device_lists.left, do: [{:sync_device_lists_left, device_lists.left}], else: []

    {:noreply, state, {:continue, changed ++ left ++ next}}
  end

  def handle_continue([{:sync_device_lists_changed, [changed | rest]} | next], state) do
    # Logger.warning("sync_device_lists_changed: #{inspect(changed)}")
    _ = changed
    {:noreply, state, {:continue, [{:sync_device_lists_changed, rest} | next]}}
  end

  def handle_continue([{:sync_device_lists_changed, []} | next], state) do
    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_device_lists_left, [left | rest]} | next], state) do
    # Logger.warning("sync_device_lists_left: #{inspect(left)}")
    _ = left
    {:noreply, state, {:continue, [{:sync_device_lists_left, rest} | next]}}
  end

  def handle_continue([{:sync_device_lists_left, []} | next], state) do
    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_rooms, rooms} | next], state) do
    sync_fun = fn inner ->
      fn {room_id, data} ->
        with {:ok, room_pid} <- RoomSupervisor.start_room(room_id) do
          :ok = inner.(room_pid, data)
        else
          {:error, reason} ->
            Logger.error("Failed to get room: #{inspect(reason)}")
        end
      end
    end

    if rooms.invite, do: Enum.each(rooms.invite, sync_fun.(&Room.sync_invite/2))
    if rooms.join, do: Enum.each(rooms.join, sync_fun.(&Room.sync_join/2))
    if rooms.knock, do: Enum.each(rooms.knock, sync_fun.(&Room.sync_knock/2))
    if rooms.leave, do: Enum.each(rooms.leave, sync_fun.(&Room.sync_leave/2))

    {:noreply, state, {:continue, next}}
  end

  defp sync_process(parent, session, query \\ nil) do
    case @api.sync(session, query) do
      {:ok, sync} ->
        send(parent, sync)
        sync_process(parent, session, %{since: sync.next_batch, timeout: :timer.seconds(30)})

      error ->
        error
    end
  end
end
