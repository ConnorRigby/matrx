defmodule Matrx.Client do
  @moduledoc """
  Everything a bot needs, as one supervised unit: logs in (or reuses the device
  stored by an earlier run), then runs the sync loop and a `Matrx.Consumer`.

      # config/runtime.exs
      config :matrx, Matrx.Client,
        homeserver: "https://matrix.example.com",
        username: "mybot",
        password: System.fetch_env!("MATRIX_PASSWORD")

      # your supervision tree
      children = [
        {Matrx.Client, MyHandler}
      ]

  `MyHandler` implements `Matrx.Consumer`. Options can also be given in the
  child spec, and win over the config: `{Matrx.Client, handler: MyHandler, username: "other"}`.

  ## Options

    * `:handler` (required): the `Matrx.Consumer` module
    * `:homeserver` (required): the homeserver URL
    * `:username` (required): localpart of the bot's user
    * `:password`: only needed when there is no stored device for this user yet
    * `:new_device`: log in again even if a device is stored, default `false`
    * `:auto_join`: join rooms the bot is invited to: `true`, or a function taking
      the `Matrx.Invite` and returning whether to join. Default `false`.
    * `:initial_history`: deliver the first timeline batch for a new local
      session, default `false`. Later restarts resume from the stored sync token.
    * `:ignore_own`, `:task_supervisor`: passed to the consumer
    * `:migrate`: bring the local database up to date first, default `true`
    * `:api`: the API module, default `Matrx.API`
    * `:name`: register the supervisor

  ## Failure

  Login happens in `start_link/1`, so a wrong password or an unreachable
  homeserver makes it return `{:error, reason}`, which stops your application
  from starting, as with an unreachable database. Once started, the sync loop
  and the consumer are restarted by this supervisor if they crash. The consumer
  starts first; if it crashes, sync restarts too, so polling never continues
  indefinitely without a consumer.

  Invites reach the handler as `:room_invite` events. Use `:auto_join` to accept
  them, for example `auto_join: &(&1.inviter == "@admin:example.com")`.
  """

  use Supervisor

  alias Matrx.{Consumer, Session, SyncLongPoll}

  @required [:handler, :homeserver, :username]

  @doc false
  def child_spec(handler) when is_atom(handler) and not is_nil(handler),
    do: child_spec(handler: handler)

  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(module() | keyword()) :: Supervisor.on_start()
  def start_link(handler) when is_atom(handler) and not is_nil(handler),
    do: start_link(handler: handler)

  def start_link(opts) when is_list(opts) do
    opts = Keyword.merge(Application.get_env(:matrx, __MODULE__, []), opts)

    with :ok <- validate(opts),
         :ok <- if(Keyword.get(opts, :migrate, true), do: Matrx.Repo.migrate(), else: :ok),
         {:ok, session} <- login(opts) do
      sup_opts = if opts[:name], do: [name: opts[:name]], else: []
      Supervisor.start_link(__MODULE__, {session, opts}, sup_opts)
    end
  end

  @doc "The session the client is logged in with, for sending outside of a handler"
  @spec session(Supervisor.supervisor()) :: Session.t()
  def session(client) do
    {_, consumer, _, _} =
      client |> Supervisor.which_children() |> List.keyfind!(Consumer, 0)

    Consumer.session(consumer)
  end

  @impl Supervisor
  def init({session, opts}) do
    sync_opts =
      opts |> Keyword.take([:api, :initial_history]) |> Keyword.put_new(:initial_history, false)

    consumer_opts =
      Keyword.take(opts, [:handler, :ignore_own, :task_supervisor, :auto_join, :api])

    children = [
      %{
        id: Consumer,
        start: {Consumer, :start_link, [[session: session] ++ consumer_opts]}
      },
      %{
        id: SyncLongPoll,
        start: {SyncLongPoll, :start_link, [[session: session] ++ sync_opts]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp validate(opts) do
    case Enum.reject(@required, &Keyword.get(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_options, missing}}
    end
  end

  defp login(opts) do
    Session.restore_or_login(
      opts[:homeserver],
      opts[:username],
      opts[:password],
      Keyword.take(opts, [:new_device, :api])
    )
  end
end
