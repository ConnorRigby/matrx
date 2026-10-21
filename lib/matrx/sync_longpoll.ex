defmodule Matrx.SyncLongPoll do
  use GenServer
  require Logger
  alias Matrx.Presence
  alias Matrx.RoomSupervisor
  alias Matrx.Room
  alias Matrx.Crypto.{Devices, KeyRequests, RoomMessages, ToDevice}
  alias Matrx.{Repo, Session, SyncDelivery}

  @key_request_delay_ms :timer.seconds(5)

  @doc """
  Start a sync session. Only one sync process may own a stored session at a
  time. `:initial_history` defaults to `true` for this low-level interface;
  `Matrx.Client` and `Matrx.Dev` default to `false` for bot usage.
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
    Process.flag(:trap_exit, true)
    session = Keyword.fetch!(args, :session)

    case register_session(session) do
      :ok -> init_sync(args, session)
      {:error, pid} -> {:stop, {:already_syncing, pid}}
    end
  end

  defp register_session(%Session{id: id}) do
    case Registry.register(Matrx.SyncRegistry, id, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, pid}} -> {:error, pid}
    end
  end

  defp register_session(_session), do: :ok

  defp init_sync(args, session) do
    server = self()
    api = Keyword.get(args, :api, Matrx.API)
    token = if match?(%Session{}, session), do: Repo.get!(Session, session.id).sync_token
    query = if token, do: %{since: token, full_state: true}

    sync =
      :erlang.spawn_opt(fn -> sync_process(server, api, session, query) end, [:link, :monitor])

    state = %{
      session: session,
      api: api,
      sync: sync,
      next_batch: nil,
      suppress_history: is_nil(token) and not Keyword.get(args, :initial_history, true),
      one_time_key_counts: nil,
      # encrypted events waiting for their room key, as {room_id, event}
      pending: [],
      # how long an event waits for its key to arrive on its own before we ask for it
      key_request_delay: Keyword.get(args, :key_request_delay, @key_request_delay_ms),
      key_request_timer: nil,
      awaiting_sync: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:await_sync, from, %{awaiting_sync: awaiting_sync} = state) do
    if awaiting_sync, do: GenServer.reply(awaiting_sync, false)
    {:noreply, %{state | awaiting_sync: from}, :hibernate}
  end

  @impl GenServer
  def terminate(_reason, %{sync: {pid, _}}) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl GenServer
  def handle_info({:EXIT, pid, _reason}, %{sync: {pid, _}} = state), do: {:noreply, state}

  def handle_info({:DOWN, mon, :process, pid, reason}, %{sync: {pid, mon}} = state)
      when reason in [:normal, :killed] do
    {:noreply, %{state | sync: nil}}
  end

  def handle_info({:DOWN, mon, :process, pid, reason}, %{sync: {pid, mon}} = state) do
    Logger.error(%{sync_error: reason})
    {:stop, reason, %{state | sync: nil}}
  end

  def handle_info(:request_missing_keys, %{session: %Matrx.Session{} = session} = state) do
    state = retry_pending(%{state | key_request_timer: nil})
    KeyRequests.request(session, state.pending, api: state.api)
    {:noreply, state}
  end

  def handle_info(%Matrx.API.Sync{} = sync, state) do
    account_data =
      if sync.account_data, do: [{:sync_account_data, sync.account_data.events}], else: []

    presence = if sync.presence, do: [{:sync_presence, sync.presence.events}], else: []
    rooms = if sync.rooms, do: [{:sync_rooms, sync.rooms}], else: []
    to_device = if sync.to_device, do: [{:sync_to_device, sync.to_device.events}], else: []
    device_lists = if sync.device_lists, do: [{:sync_device_lists, sync.device_lists}], else: []

    keys =
      if replenish_keys?(state, sync),
        do: [{:replenish_keys, sync.device_one_time_keys_count}],
        else: []

    events = keys ++ account_data ++ presence ++ rooms ++ to_device ++ device_lists
    if state.awaiting_sync, do: GenServer.reply(state.awaiting_sync, sync)

    state = %{
      state
      | one_time_key_counts: sync.device_one_time_keys_count,
        awaiting_sync: nil,
        next_batch: sync.next_batch
    }

    if length(events) > 0 do
      {:noreply, state, {:continue, events}}
    else
      Logger.warning("sync has no events")
      handle_continue([], state)
    end
  end

  @impl GenServer
  def handle_continue([], state) do
    if match?(%Session{}, state.session) and state.pending == [] and
         is_binary(state.next_batch) do
      state.session
      |> Ecto.Changeset.change(sync_token: state.next_batch)
      |> Repo.update!()
    end

    if state.sync do
      {pid, _} = state.sync
      send(pid, {:sync_processed, state.next_batch})
    end

    {:noreply, %{state | suppress_history: false}, :hibernate}
  end

  def handle_continue([{:replenish_keys, counts} | next], state) do
    case Matrx.Crypto.Keys.maybe_replenish(state.session, counts.signed_curve25519 || 0,
           api: state.api
         ) do
      {:error, reason} -> Logger.error("Failed to upload one-time keys: #{inspect(reason)}")
      _ -> :ok
    end

    {:noreply, state, {:continue, next}}
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
    :ok = Presence.sync(state.session, event)
    {:noreply, state, {:continue, [{:sync_presence, rest} | next]}}
  end

  def handle_continue([{:sync_to_device, []} | next], state) do
    {:noreply, retry_pending(state), {:continue, next}}
  end

  def handle_continue([{:sync_to_device, [event | rest]} | next], state) do
    case state.session do
      %Matrx.Session{} = session -> ToDevice.handle(session, event, api: state.api)
      _ -> Logger.warning("Unhandled device event: #{inspect(event)}")
    end

    {:noreply, state, {:continue, [{:sync_to_device, rest} | next]}}
  end

  def handle_continue([{:sync_device_lists, device_lists} | next], state) do
    changed =
      if device_lists.changed, do: [{:sync_device_lists_changed, device_lists.changed}], else: []

    left =
      if device_lists.left, do: [{:sync_device_lists_left, device_lists.left}], else: []

    {:noreply, state, {:continue, changed ++ left ++ next}}
  end

  def handle_continue([{:sync_device_lists_changed, changed} | next], state) do
    with %Matrx.Session{} = session <- state.session do
      :ok = Devices.mark_outdated(session, changed)

      case Devices.refresh(session, api: state.api) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Failed to refresh devices: #{inspect(reason)}")
      end
    end

    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_device_lists_left, left} | next], state) do
    with %Matrx.Session{} = session <- state.session, do: Devices.untrack(session, left)
    {:noreply, state, {:continue, next}}
  end

  def handle_continue([{:sync_rooms, rooms} | next], state) do
    {rooms, state} = decrypt_rooms(rooms, state)

    sync_fun = fn inner ->
      fn {room_id, data} ->
        with {:ok, room_pid} <- RoomSupervisor.start_room(room_id) do
          :ok = inner.(room_pid, data)
          # Wait for the preceding cast before acknowledging this sync batch.
          Room.dump_state(room_pid)
        else
          {:error, reason} ->
            raise "Failed to get room #{room_id}: #{inspect(reason)}"
        end
      end
    end

    touched = Map.keys(rooms.join || %{}) ++ Map.keys(rooms.leave || %{})
    before = state_members_before(state, touched)

    if rooms.invite, do: broadcast_invites(state, rooms.invite)
    if rooms.join, do: Enum.each(rooms.join, sync_fun.(&Room.sync_join/2))
    if rooms.knock, do: Enum.each(rooms.knock, sync_fun.(&Room.sync_knock/2))
    if rooms.leave, do: Enum.each(rooms.leave, sync_fun.(&Room.sync_leave/2))

    if rooms.join, do: track_encrypted_room_members(state, Map.keys(rooms.join))
    untrack_departed_users(state.session, before, touched)

    {:noreply, state, {:continue, next}}
  end

  defp broadcast_invites(%{session: %Matrx.Session{user_id: user_id}}, invites) do
    Enum.each(invites, fn {room_id, invited} ->
      Room.broadcast_invite(user_id, room_id, invited)
    end)
  end

  defp broadcast_invites(_state, _invites), do: :ok

  @max_pending 500

  defp decrypt_rooms(%{join: join, leave: leave} = rooms, %{session: %Matrx.Session{}} = state) do
    {join, state} = decrypt_room_map(join, state)
    {leave, state} = decrypt_room_map(leave, state)
    {%{rooms | join: join, leave: leave}, state}
  end

  defp decrypt_rooms(rooms, state), do: {rooms, state}

  defp decrypt_room_map(nil, state), do: {nil, state}

  defp decrypt_room_map(rooms, state) do
    Enum.reduce(rooms, {%{}, state}, fn {room_id, room}, {acc, state} ->
      {events, state} =
        Enum.reduce(room.timeline.events, {[], state}, fn event, {events, state} ->
          cond do
            is_binary(event.state_key) ->
              {[event | events], state}

            state.suppress_history ->
              if is_binary(event.event_id) do
                SyncDelivery.claim(state.session, room_id, event, "clear")
                SyncDelivery.claim(state.session, room_id, event, "encrypted")
              end

              {events, state}

            true ->
              {event, state} = decrypt_event(room_id, event, state)

              if claim_delivery(state, room_id, event),
                do: {[event | events], state},
                else: {events, state}
          end
        end)

      {Map.put(acc, room_id, %{room | timeline: %{room.timeline | events: Enum.reverse(events)}}),
       state}
    end)
  end

  defp decrypt_event(room_id, event, state) do
    if RoomMessages.encrypted?(event) do
      case RoomMessages.decrypt(state.session, room_id, event) do
        {:ok, decrypted} ->
          {decrypted, state}

        {:error, :unknown_session} ->
          {event, add_pending(state, room_id, event)}

        {:error, reason} ->
          Logger.warning("Could not decrypt #{event.event_id} in #{room_id}: #{inspect(reason)}")
          {event, state}
      end
    else
      {event, state}
    end
  end

  defp add_pending(state, room_id, event) do
    %{state | pending: Enum.take(state.pending ++ [{room_id, event}], -@max_pending)}
    |> schedule_key_request()
  end

  defp claim_delivery(state, room_id, %{event_id: id} = event) when is_binary(id),
    do: SyncDelivery.claim(state.session, room_id, event)

  defp claim_delivery(_state, room_id, _event) do
    Logger.warning("Ignoring timeline event without event_id in #{room_id}")
    false
  end

  defp schedule_key_request(%{key_request_timer: nil} = state) do
    timer = Process.send_after(self(), :request_missing_keys, state.key_request_delay)
    %{state | key_request_timer: timer}
  end

  defp schedule_key_request(state), do: state

  # Called once new room keys may have arrived
  defp retry_pending(%{pending: []} = state), do: state

  defp retry_pending(state) do
    pending =
      Enum.filter(state.pending, fn {room_id, event} ->
        case RoomMessages.decrypt(state.session, room_id, event) do
          {:ok, decrypted} ->
            if claim_delivery(state, room_id, decrypted),
              do: Room.broadcast_event(room_id, decrypted)

            false

          {:error, :unknown_session} ->
            true

          {:error, reason} ->
            Logger.warning(
              "Could not decrypt #{event.event_id} in #{room_id}: #{inspect(reason)}"
            )

            false
        end
      end)

    %{state | pending: pending}
  end

  # Room.sync_join/2 is a cast, but the state calls below come from the same
  # process, so they are handled after it and see the updated room state.
  defp track_encrypted_room_members(%{session: %Matrx.Session{} = session} = state, room_ids) do
    users =
      room_ids
      |> Enum.flat_map(&encrypted_room_members/1)
      |> Enum.uniq()

    if users != [] do
      :ok = Devices.track(session, users)

      case Devices.refresh(session, api: state.api) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Failed to refresh devices: #{inspect(reason)}")
      end
    end
  end

  defp track_encrypted_room_members(_state, _room_ids), do: :ok

  defp encrypted_room_members(room_id) do
    case Room.encryption_info(room_id) do
      {:ok, %{members: members}} -> members
      :error -> []
    end
  end

  defp state_members_before(%{session: %Matrx.Session{} = session}, room_ids),
    do: joined_encrypted_members(session, room_ids)

  defp state_members_before(_state, _room_ids), do: MapSet.new()

  # Users in encrypted rooms we have joined; rooms we are not in don't count
  defp joined_encrypted_members(session, room_ids) do
    room_ids
    |> Enum.flat_map(fn room_id ->
      case Room.encryption_info(room_id) do
        {:ok, %{joined: joined, members: members}} ->
          if session.user_id in joined, do: members, else: []

        :error ->
          []
      end
    end)
    |> MapSet.new()
  end

  defp known_room_ids do
    Matrx.RoomRegistry |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # Stop tracking users who were in the rooms of this sync, but share no
  # encrypted room with us any more
  defp untrack_departed_users(%Matrx.Session{} = session, before, room_ids) do
    gone = MapSet.difference(before, joined_encrypted_members(session, room_ids))
    still_shared = joined_encrypted_members(session, known_room_ids())

    departed =
      gone
      |> MapSet.difference(still_shared)
      |> MapSet.delete(session.user_id)
      |> MapSet.to_list()

    if departed != [], do: Devices.untrack(session, departed)
    :ok
  end

  defp untrack_departed_users(_session, _before, _room_ids), do: :ok

  # Only real sessions own an Olm account; the server's count is absent on most syncs
  defp replenish_keys?(%{session: %Matrx.Session{}}, %{device_one_time_keys_count: counts}),
    do: counts != nil

  defp replenish_keys?(_state, _sync), do: false

  defp sync_process(parent, api, session, query) do
    case api.sync(session, query) do
      {:ok, sync} ->
        send(parent, sync)

        receive do
          {:sync_processed, token} ->
            sync_process(parent, api, session, %{since: token, timeout: :timer.seconds(30)})
        end

      {:error, reason} ->
        exit({:sync_failed, reason})
    end
  end
end
