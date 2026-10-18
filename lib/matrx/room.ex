defmodule Matrx.Room do
  use GenServer
  require Logger
  alias Matrx.Room.Timeline

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

  @doc "Subscribe the calling process to room events"
  def subscribe(room_id) do
    Phoenix.PubSub.subscribe(Matrx.PubSub, "rooms:#{room_id}")
  end

  @doc "Unsubscribe the calling process to room events"
  @spec unsubscribe(room_id()) :: :ok
  def unsubscribe(room_id) do
    Phoenix.PubSub.unsubscribe(Matrx.PubSub, "rooms:#{room_id}")
  end

  def sync_invite(room_pid, invite) when is_pid(room_pid) do
    GenServer.cast(room_pid, {:sync_invite, invite})
  end

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

  @impl GenServer
  def handle_cast({:sync_invite, invite}, state) do
    Logger.error(":sync_invite not implemented: #{inspect(invite)}")
    {:noreply, state}
  end

  def handle_cast({:sync_join, join}, state) do
    handle_timeline(join.timeline, state)
  end

  def handle_cast({:sync_knock, knock}, state) do
    Logger.error(":sync_knock not implemented: #{inspect(knock)}")
    {:noreply, state}
  end

  def handle_cast({:sync_leave, leave}, state) do
    handle_timeline(leave.timeline, state)
  end

  def handle_timeline(timeline, state) do
    state = %{state | timeline: Timeline.reduce_state(state.timeline, timeline.events)}
    state = dispatch_timeline_events(timeline, timeline.events, state)
    {:noreply, state, :hibernate}
  end

  def dispatch_timeline_events(_tl, [], state) do
    state
  end

  def dispatch_timeline_events(timeline, [%{state_key: nil} = event | next], state) do
    Phoenix.PubSub.broadcast(Matrx.PubSub, "rooms:#{state.room_id}", event)
    dispatch_timeline_events(timeline, next, state)
  end

  def dispatch_timeline_events(timeline, [_event | next], state) do
    dispatch_timeline_events(timeline, next, state)
  end
end
