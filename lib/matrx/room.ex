defmodule Matrx.Room do
  use GenServer
  require Logger
  alias Matrx.Crypto.RoomEncryption
  alias Matrx.Room.Timeline

  @events_topic "events"

  @type room_id :: String.t()
  @type event_content :: Timeline.event_content()
  @type event_type :: Timeline.event_type()
  @type state_key :: Timeline.state_key()

  @spec fetch_state(pid(), event_type(), state_key()) :: {:ok, map()} | :error
  def fetch_state(room_pid, type, state_key) when is_pid(room_pid) do
    GenServer.call(room_pid, {:fetch_state, type, state_key})
  end

  @spec lookup_state(pid(), event_type()) :: [event_content()] | nil
  def lookup_state(room_pid, type) when is_pid(room_pid) do
    GenServer.call(room_pid, {:lookup_state, type})
  end

  @spec dump_state(pid()) :: [{{event_type(), state_key()}, event_content()}]
  def dump_state(room_pid) do
    GenServer.call(room_pid, :dump_state)
  end

  @doc """
  The encryption settings of an encrypted room, the users (joined and invited)
  who should get its keys, and those who have joined. `:error` if the room is
  unknown or not encrypted.
  """
  @spec encryption_info(room_id()) ::
          {:ok, %{encryption: struct(), members: [String.t()], joined: [String.t()]}} | :error
  def encryption_info(room_id) do
    case Matrx.RoomSupervisor.whereis(room_id) do
      nil -> :error
      room_pid -> GenServer.call(room_pid, :encryption_info)
    end
  end

  @doc """
  Send an event to the room, encrypting it if the room is encrypted.

  Sends are handled one at a time by the room process, so two sends can't create
  two Megolm sessions. The call waits for uploads and server-directed rate-limit
  delays rather than timing out while a send is still in progress. Options: `:api`.
  """
  @spec send_event(room_id(), Matrx.Session.t(), String.t(), map(), keyword()) ::
          {:ok, %{event_id: String.t()}} | {:error, term()}
  def send_event(room_id, session, type, content, opts \\ []) do
    case Matrx.RoomSupervisor.whereis(room_id) do
      nil -> {:error, :unknown_room}
      room_pid -> GenServer.call(room_pid, {:send_event, session, type, content, opts}, :infinity)
    end
  end

  @doc "Subscribe the calling process to room events"
  def subscribe(room_id) do
    Phoenix.PubSub.subscribe(Matrx.PubSub, "rooms:#{room_id}")
  end

  @doc "Unsubscribe the calling process to room events"
  @spec unsubscribe(room_id()) :: :ok
  def unsubscribe(room_id) do
    Phoenix.PubSub.unsubscribe(Matrx.PubSub, "rooms:#{room_id}")
  end

  @doc """
  Deliver an event to the room's subscribers (as the bare event), and to
  `Matrx.Consumer`s (as `{:room_event, room_id, event}` on `events_topic/0`).
  """
  def broadcast_event(room_id, event) do
    Phoenix.PubSub.broadcast(Matrx.PubSub, "rooms:#{room_id}", event)
    Phoenix.PubSub.broadcast(Matrx.PubSub, @events_topic, {:room_event, room_id, event})
  end

  @doc """
  Publish an invite of `user_id` on the events topic as
  `{:room_invite, user_id, room_id, %InvitedRoom{}}`. Invites don't start a room
  process, as the user hasn't joined.
  """
  def broadcast_invite(user_id, room_id, invited_room) do
    Phoenix.PubSub.broadcast(
      Matrx.PubSub,
      @events_topic,
      {:room_invite, user_id, room_id, invited_room}
    )
  end

  @doc "PubSub topic carrying the events of every room"
  def events_topic, do: @events_topic

  def sync_join(room_pid, join) when is_pid(room_pid) do
    GenServer.cast(room_pid, {:sync_join, join})
  end

  def sync_knock(room_pid, knock) when is_pid(room_pid) do
    GenServer.cast(room_pid, {:sync_knock, knock})
  end

  def sync_leave(room_pid, leave) when is_pid(room_pid) do
    GenServer.cast(room_pid, {:sync_leave, leave})
  end

  @doc false
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)

    GenServer.start_link(
      __MODULE__,
      room_id,
      name: via(room_id)
    )
  end

  @doc false
  def via(room_id) do
    {:via, Registry, {Matrx.RoomRegistry, room_id}}
  end

  @impl GenServer
  def init(room_id) do
    state = %{
      room_id: room_id,
      timeline: Timeline.init(room_id)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:fetch_state, type, state_key}, _from, state) do
    {:reply, Timeline.fetch_state(state.timeline, type, state_key), state}
  end

  def handle_call({:lookup_state, type}, _from, state) do
    {:reply, Timeline.lookup_state(state.timeline, type), state}
  end

  def handle_call(:dump_state, _from, state) do
    {:reply, Timeline.dump_state(state.timeline), state}
  end

  def handle_call(:encryption_info, _from, state) do
    {:reply, encryption_info_from(state.timeline), state}
  end

  def handle_call({:send_event, session, type, content, opts}, _from, state) do
    {:reply, do_send_event(state, session, type, content, opts), state}
  end

  @impl GenServer
  def handle_cast({:sync_join, join}, state) do
    handle_timeline(join, state)
  end

  def handle_cast({:sync_knock, knock}, state) do
    Logger.error(":sync_knock not implemented: #{inspect(knock)}")
    {:noreply, state}
  end

  def handle_cast({:sync_leave, leave}, state) do
    handle_timeline(leave, state)
  end

  def handle_timeline(room, state) do
    timeline = room.timeline
    state = %{state | timeline: Timeline.reduce_state(state.timeline, state_events(room))}
    state = %{state | timeline: Timeline.reduce_state(state.timeline, timeline.events)}
    state = dispatch_timeline_events(timeline, timeline.events, state)
    {:noreply, state, :hibernate}
  end

  defp encryption_info_from(timeline) do
    with {:ok, encryption} <- Timeline.fetch_state(timeline, "m.room.encryption", "") do
      members = Timeline.lookup_state(timeline, "m.room.member") || []

      with_membership = fn memberships ->
        for {user_id, %{membership: membership}} <- members,
            membership in memberships,
            do: user_id
      end

      {:ok,
       %{
         encryption: encryption,
         members: with_membership.([:join, :invite]),
         joined: with_membership.([:join])
       }}
    end
  end

  # A crash here would restart the room with empty state
  defp do_send_event(state, session, type, content, opts) do
    api = Keyword.get(opts, :api, Matrx.API)

    case encryption_info_from(state.timeline) do
      {:ok, info} ->
        RoomEncryption.send_event(
          session,
          state.room_id,
          type,
          content,
          Keyword.put(opts, :room, info)
        )

      :error ->
        api.send_room_message(
          session,
          state.room_id,
          RoomEncryption.transaction_id(),
          type,
          content
        )
    end
  rescue
    exception -> {:error, {:exception, exception}}
  end

  defp state_events(%{state: %{events: events}}), do: events
  defp state_events(_room), do: []

  def dispatch_timeline_events(_tl, [], state) do
    state
  end

  def dispatch_timeline_events(timeline, [%{state_key: nil} = event | next], state) do
    broadcast_event(state.room_id, event)
    dispatch_timeline_events(timeline, next, state)
  end

  def dispatch_timeline_events(timeline, [_event | next], state) do
    dispatch_timeline_events(timeline, next, state)
  end
end
