defmodule Matrx.Consumer do
  @moduledoc """
  Receives the events of a logged in client, modelled after `Nostrum.Consumer`
  but without macros. A consumer is a plain module implementing the
  `c:handle_event/1` callback, run by a supervised process you start yourself:

      defmodule MyBot do
        @behaviour Matrx.Consumer

        @impl true
        def handle_event({:message_create, message, ctx}) do
          if message.body == "!ping", do: Matrx.Message.reply(ctx.session, message, "pong")
        end

        def handle_event(_event), do: :ok
      end

      children = [
        {Matrx.SyncLongPoll, session: session},
        {Matrx.Consumer, handler: MyBot, session: session}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Every event is handled in its own task under `Matrx.TaskSupervisor` (or the
  `:task_supervisor` you pass), so a slow or crashing handler affects neither
  other events nor the consumer. The price is that events may be handled out of
  order. The return value of the handler is ignored.

  ## Events

  Events are `{type, payload, context}` tuples, with a `t:context/0`:

    * `{:message_create, %Matrx.Message{}, ctx}`: a `m.room.message`, decrypted
      if it was encrypted. Your own messages are left out unless you pass
      `ignore_own: false`.
    * `{:message_undecryptable, %Matrx.Message{}, ctx}`: an encrypted message we
      have no key for (yet). If the key arrives later, it is delivered again as
      `:message_create`. `body` is `nil`.
    * `{:room_invite, %Matrx.Invite{}, ctx}`: the user was invited to a room.
      Accept it with `Matrx.Invite.accept/3`, or set `:auto_join`, below.
      Invites that were still open when the client started are delivered too.
    * `{:event, %{room_id: room_id, event: %Matrx.API.Event{}}, ctx}`: any other
      non-state event, as received.

  ## Auto-join

  `auto_join: true` accepts every invite, and `auto_join: fn invite -> boolean end`
  accepts the ones the function approves, e.g. only those from an admin. It
  defaults to `false`, since anyone can invite the bot. The handler still gets
  the `:room_invite` event, so don't also accept it there. A failed join is
  logged and not retried until the invite is delivered again.

  Only rooms the client has synced are covered, and the events of all of them,
  whichever session they were synced by.
  """

  use GenServer
  require Logger
  alias Matrx.API.Event
  alias Matrx.{Invite, Message, Room}

  defmodule Context do
    @moduledoc "Passed with every event: the session the consumer runs for"
    @enforce_keys [:session]
    defstruct [:session]
    @type t :: %__MODULE__{session: Matrx.Session.t()}
  end

  @type context :: Context.t()
  @type event ::
          {:message_create, Message.t(), context()}
          | {:message_undecryptable, Message.t(), context()}
          | {:room_invite, Invite.t(), context()}
          | {:event, %{room_id: String.t(), event: Event.t()}, context()}

  @callback handle_event(event()) :: any()

  @doc """
  Start a consumer. Options:

    * `:handler` (required): a module implementing this behaviour
    * `:session` (required): the `Matrx.Session` events are handled for
    * `:task_supervisor`: a `Task.Supervisor`, default `Matrx.TaskSupervisor`
    * `:ignore_own`: leave out your own messages, default `true`
    * `:auto_join`: `true`, or a function deciding per `Matrx.Invite`, default `false`
    * `:api`: the API module, default `Matrx.API`
    * `:name`: register the process
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The session the consumer handles events for"
  @spec session(GenServer.server()) :: Matrx.Session.t()
  def session(consumer), do: GenServer.call(consumer, :session)

  @doc """
  Turn a room event into a consumer event, or `:skip` for events that are not
  delivered (state events, and your own messages unless `ignore_own: false`).
  """
  @spec translate(String.t(), Event.t(), context(), keyword()) :: event() | :skip
  def translate(room_id, event, ctx, opts \\ [])

  def translate(_room_id, %Event{state_key: state_key}, _ctx, _opts) when is_binary(state_key),
    do: :skip

  def translate(room_id, %Event{type: "m.room.message"} = event, ctx, opts) do
    message = Message.from_event(room_id, event)

    if Keyword.get(opts, :ignore_own, true) and Message.own?(message, ctx.session),
      do: :skip,
      else: {:message_create, message, ctx}
  end

  def translate(room_id, %Event{type: "m.room.encrypted"} = event, ctx, opts) do
    message = Message.from_event(room_id, event)

    if Keyword.get(opts, :ignore_own, true) and Message.own?(message, ctx.session),
      do: :skip,
      else: {:message_undecryptable, message, ctx}
  end

  def translate(room_id, %Event{} = event, ctx, _opts),
    do: {:event, %{room_id: room_id, event: event}, ctx}

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    session = Keyword.fetch!(opts, :session)

    with {:module, _} <- Code.ensure_loaded(handler),
         true <- function_exported?(handler, :handle_event, 1) do
      :ok = Phoenix.PubSub.subscribe(Matrx.PubSub, Room.events_topic())

      {:ok,
       %{
         handler: handler,
         ctx: %Context{session: session},
         task_supervisor: Keyword.get(opts, :task_supervisor, Matrx.TaskSupervisor),
         translate_opts: Keyword.take(opts, [:ignore_own]),
         auto_join: Keyword.get(opts, :auto_join, false),
         api: Keyword.get(opts, :api, Matrx.API)
       }}
    else
      _ -> {:stop, {:invalid_handler, handler}}
    end
  end

  @impl GenServer
  def handle_call(:session, _from, state), do: {:reply, state.ctx.session, state}

  @impl GenServer
  def handle_info({:room_event, room_id, %Event{} = event}, state) do
    case translate(room_id, event, state.ctx, state.translate_opts) do
      :skip -> :ok
      consumer_event -> run(state, consumer_event)
    end

    {:noreply, state}
  end

  def handle_info({:room_invite, user_id, room_id, invited}, state) do
    if user_id == state.ctx.session.user_id do
      invite = Invite.from_sync(user_id, room_id, invited)
      run(state, {:room_invite, invite, state.ctx})
      auto_join(state, invite)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp auto_join(%{auto_join: false}, _invite), do: :ok

  defp auto_join(state, invite) do
    Task.Supervisor.start_child(state.task_supervisor, fn ->
      if approved?(state.auto_join, invite) do
        case Invite.accept(state.ctx.session, invite, api: state.api) do
          :ok -> :ok
          error -> Logger.error("Could not join #{invite.room_id}: #{inspect(error)}")
        end
      end
    end)
  end

  defp approved?(true, _invite), do: true
  defp approved?(fun, invite) when is_function(fun, 1), do: fun.(invite) == true
  defp approved?(_, _invite), do: false

  defp run(state, consumer_event) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           state.handler.handle_event(consumer_event)
         end) do
      {:ok, _pid} -> :ok
      error -> Logger.error("Could not start handler task: #{inspect(error)}")
    end
  end
end
