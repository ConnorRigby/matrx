defmodule Matrx.Room.Timeline do
  defstruct [:room_id, :store]

  @type room_id() :: String.t()
  @type event_type() :: String.t()
  @type state_key() :: String.t()
  @type event_content() :: map()

  @type t :: %__MODULE__{
          room_id: room_id(),
          store: :ets.table()
        }

  @spec init(room_id()) :: t()
  def init(room_id) do
    store = :ets.new(:undefined, [:set])
    %__MODULE__{room_id: room_id, store: store}
  end

  @spec fetch_state(t(), event_type(), state_key()) :: {:ok, event_content()} | :error
  def fetch_state(timeline, type, state_key) do
    case :ets.lookup(timeline.store, {type, state_key}) do
      [] ->
        :error

      results ->
        {{^type, ^state_key}, content} = List.last(results)
        {:ok, content}
    end
  end

  @spec lookup_state(t(), event_type()) :: [event_content()] | nil
  def lookup_state(timeline, type) do
    case :ets.match_object(timeline.store, {{type, :_}, :_}) do
      [] ->
        nil

      results ->
        Enum.map(
          results,
          fn {{_type, state_key}, content} ->
            {state_key, content}
          end
        )
    end
  end

  @spec dump_state(t()) :: [{{event_type(), state_key()}, event_content()}]
  def dump_state(timeline) do
    :ets.match_object(timeline.store, {{:_, :_}, :_})
  end

  # https://spec.matrix.org/v1.19/client-server-api/#types-of-room-events
  # Enumerate the timeline events and reduce any necessary state.
  # if `event.state_key` is `nil`, then the event is "one-off", like a
  # `m.room.message` or similar.
  @spec reduce_state(t(), [
          %{
            required(:type) => event_type(),
            required(:state_key) => nil | state_key(),
            required(:content) => event_content()
          }
        ]) :: t()
  def reduce_state(timeline, []), do: timeline

  def reduce_state(timeline, [%{state_key: nil} | next]) do
    reduce_state(timeline, next)
  end

  def reduce_state(timeline, [%{type: type, state_key: state_key, content: content} | next]) do
    true = :ets.insert(timeline.store, {{type, state_key}, content})
    reduce_state(timeline, next)
  end
end
