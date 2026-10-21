defmodule Matrx.Presence do
  @moduledoc """
  A user's Matrix presence, delivered as `{:presence_update, presence, ctx}`.

  `presence` is `:online`, `:offline`, or `:unavailable`. Optional fields are
  `nil` when absent; `last_active_ago` is milliseconds before `observed_at`,
  not a live counter. `event` retains the original sync event.

  in-memory cache holds the latest sync observation per stored
  session and user. It survives sync/consumer restarts, but not application
  restarts. Missing entries mean unknown, not offline. Homeservers may disable
  presence or limit whose presence is visible. Initial sync presence is
  delivered even when message history is suppressed.
  """

  use GenServer
  require Logger
  alias Matrx.API.Event
  alias Matrx.Session

  @enforce_keys [:user_id, :presence, :observed_at]
  defstruct [
    :user_id,
    :presence,
    :status_msg,
    :currently_active,
    :last_active_ago,
    :observed_at,
    :event
  ]

  @type status :: :online | :offline | :unavailable
  @type t :: %__MODULE__{
          user_id: String.t(),
          presence: status(),
          status_msg: String.t() | nil,
          currently_active: boolean() | nil,
          last_active_ago: non_neg_integer() | nil,
          observed_at: DateTime.t(),
          event: Event.t() | nil
        }

  @doc "Build a presence observation from an `m.presence` sync event."
  @spec from_event(Event.t()) :: t()
  def from_event(%Event{type: "m.presence", sender: user_id, content: content} = event)
      when is_binary(user_id) do
    %{from_response(user_id, content) | event: event}
  end

  @doc "Build a presence observation from a string-keyed homeserver response."
  @spec from_response(String.t(), map()) :: t()
  def from_response(user_id, %{"presence" => presence} = content) do
    %__MODULE__{
      user_id: user_id,
      presence: parse_status(presence),
      status_msg: content["status_msg"],
      currently_active: content["currently_active"],
      last_active_ago: content["last_active_ago"],
      observed_at: DateTime.utc_now()
    }
  end

  @doc "Read the last synced presence for this session and user, or `:error` if unknown."
  @spec get_cached(Session.t(), String.t()) :: {:ok, t()} | :error
  def get_cached(%Session{id: id}, user_id) when is_binary(id),
    do: GenServer.call(__MODULE__, {:get, id, user_id})

  @doc """
  Fetch a user's presence from the homeserver. Takes an `:api` option.
  Does not change the sync cache or emit a consumer event.
  """
  @spec fetch(Session.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def fetch(%Session{} = session, user_id, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    with {:ok, content} <- api.get_presence(session, user_id) do
      {:ok, from_response(user_id, content)}
    end
  end

  @doc """
  Set this session's user's presence on the homeserver.

  Takes `:api` and optional `:status_msg` (a string; `""` clears it).
  Omitting `:status_msg` leaves it unchanged. The cache and consumer events
  are updated only when the homeserver reports presence through sync.
  """
  @spec set(Session.t(), status(), keyword()) :: :ok | {:error, term()}
  def set(%Session{} = session, presence, opts \\ [])
      when presence in [:online, :offline, :unavailable] do
    api = Keyword.get(opts, :api, Matrx.API)
    payload = %{"presence" => Atom.to_string(presence)}

    payload =
      case Keyword.fetch(opts, :status_msg) do
        :error -> payload
        {:ok, text} when is_binary(text) -> Map.put(payload, "status_msg", text)
        {:ok, value} -> raise ArgumentError, "status_msg must be a string, got: #{inspect(value)}"
      end

    api.set_presence(session, payload)
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def topic(%Session{id: id}) when is_binary(id), do: "presence:#{id}"

  @doc false
  def sync(%Session{id: id} = session, %Event{type: "m.presence"} = event)
      when is_binary(id) do
    GenServer.call(__MODULE__, {:sync, id, topic(session), from_event(event)})
  end

  def sync(_session, %Event{type: type} = event) when type != "m.presence" do
    Logger.warning("Unhandled presence event: #{inspect(event)}")
    :ok
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:get, id, user_id}, _from, state),
    do: {:reply, Map.fetch(state, {id, user_id}), state}

  def handle_call({:sync, id, topic, presence}, _from, state) do
    state = Map.put(state, {id, presence.user_id}, presence)
    :ok = Phoenix.PubSub.broadcast(Matrx.PubSub, topic, {:presence_update, presence})
    {:reply, :ok, state}
  end

  defp parse_status("online"), do: :online
  defp parse_status("offline"), do: :offline
  defp parse_status("unavailable"), do: :unavailable
end
