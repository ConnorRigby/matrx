defmodule Matrx.Dev do
  @moduledoc """
  Shortcuts for trying the client by hand from `iex -S mix`.

      iex> import Matrx.Dev
      iex> session = connect("https://matrix.pressy4pie.dev", "bakedbot")
      iex> join(session, "!eiyZOmiCufWnUlRabT:matrix.pressy4pie.dev")
      iex> watch("!eiyZOmiCufWnUlRabT:matrix.pressy4pie.dev")
      iex> say(session, "!eiyZOmiCufWnUlRabT:matrix.pressy4pie.dev", "hello from elixir")

  `connect/3` reuses the device it stored earlier, so restarting IEx doesn't
  create a new device (and a new Olm account) every time.
  """

  import Ecto.Query, only: [from: 2]
  alias Matrx.{Repo, Room, Session, SyncLongPoll}

  @sync_name Matrx.Dev.Sync

  @doc """
  Log in (or reload the stored device for this user and server) and start
  syncing. Returns the session.

  Options: `:password` (default `MATRIX_PASSWORD`), `:new_device` to force a
  fresh login, `:initial_history` (default `false`, skips the first history
  batch for a new local session), and `:api`. Later starts resume from the
  stored sync token.
  """
  @spec connect(String.t(), String.t(), keyword()) :: Session.t()
  def connect(homeserver, username, opts \\ []) do
    migrate()
    uri = URI.parse(homeserver)
    session = login(uri, username, opts)
    start_sync(session, opts)
    session
  end

  @doc """
  (Re)start the Dev sync loop for a session, stopping any previous Dev loop.
  Options: `:api` and `:initial_history` (default `false`).
  """
  @spec start_sync(Session.t(), keyword()) :: pid()
  def start_sync(session, opts \\ []) do
    stop_sync()

    args =
      [session: session] ++
        (opts
         |> Keyword.take([:api, :initial_history])
         |> Keyword.put_new(:initial_history, false))

    {:ok, pid} = SyncLongPoll.start_link(args, name: @sync_name)
    # a crash in sync shouldn't take the IEx shell down with it
    Process.unlink(pid)
    pid
  end

  @doc "Stop the sync loop"
  @spec stop_sync() :: :ok
  def stop_sync do
    with pid when is_pid(pid) <- Process.whereis(@sync_name), do: GenServer.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Is the sync loop running? It stops quietly if a sync request fails."
  @spec syncing?() :: boolean()
  def syncing?, do: Process.whereis(@sync_name) != nil

  @doc "Wait for the next sync to arrive. Its rooms are handled just after this returns."
  def await_sync(timeout \\ 30_000), do: SyncLongPoll.await_sync(@sync_name, timeout)

  @doc "Join a room by id or alias"
  def join(session, room_id_or_alias, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)
    api.join_room(session, room_id_or_alias)
  end

  @doc """
  Create cross-signing keys for the account and sign this device, so that
  other devices of the account are answered when they ask for room keys.

  Fails with `:cross_signing_exists` if the account already has cross-signing
  keys; `reset: true` replaces them, which un-verifies your other devices.
  Pass `password:` when the server asks for it.
  """
  @spec cross_sign(Session.t(), keyword()) :: :ok | {:error, term()}
  def cross_sign(session, opts \\ []) do
    opts = Keyword.put_new(opts, :password, System.get_env("MATRIX_PASSWORD"))
    Matrx.Crypto.CrossSigning.bootstrap(session, Keyword.reject(opts, fn {_, v} -> is_nil(v) end))
  end

  @doc """
  Delete everything stored locally that does not belong to `session`: other
  logins with their Olm accounts, Olm/Megolm sessions, tracked devices,
  cross-signing keys and key requests, plus leftovers without an owner.

  Meant for a bot with a single device. It only touches the local database, so
  cross-signing keys already uploaded to the server stay there until you call
  `cross_sign(session, reset: true)`. Returns the number of logins removed.
  """
  @spec clear_other_data(Session.t()) :: {:ok, non_neg_integer()}
  def clear_other_data(%Session{id: id, account_id: account_id}) do
    {:ok, removed} =
      Repo.transaction(fn ->
        # sessions, and everything owned by them, go with their account
        {removed, _} = Repo.delete_all(from(a in Matrx.Olm.Account, where: a.id != ^account_id))
        Repo.delete_all(from(s in Session, where: s.id != ^id))

        for table <- ~w(olm_inbound_sessions olm_outbound_sessions
                        megolm_inbound_sessions megolm_outbound_sessions) do
          Repo.delete_all(from(r in table, where: is_nil(r.owner_id) or r.owner_id != ^id))
        end

        Repo.delete_all(
          from(i in Matrx.Megolm.MessageIndex,
            where:
              i.session_id not in subquery(
                from(s in "megolm_inbound_sessions", select: s.session_id)
              )
          )
        )

        removed
      end)

    {:ok, removed}
  end

  @doc """
  Delete every other device of the account from the homeserver, and replace
  the account's cross-signing keys with fresh ones signed by this device. The
  server can't delete cross-signing keys, only replace them.

  Servers ask for the account password for both, so pass `password:` or set
  `MATRIX_PASSWORD`. This logs out and un-verifies every other device and
  deletes the one-time keys they uploaded. Pass `cross_signing: false` to
  keep the cross-signing keys. Use `clear_other_data/1` for the local data.

  Returns `{:ok, deleted_device_ids}`.
  """
  @spec clear_remote_data(Session.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def clear_remote_data(%Session{} = session, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)
    password = Keyword.get(opts, :password) || System.get_env("MATRIX_PASSWORD")

    with {:ok, devices} <- api.list_devices(session),
         others = for(%{"device_id" => id} <- devices, id != session.device_id, do: id),
         :ok <- delete_devices(session, api, others, password),
         :ok <-
           reset_cross_signing(session, api, password, Keyword.get(opts, :cross_signing, true)) do
      {:ok, others}
    end
  end

  defp delete_devices(_session, _api, [], _password), do: :ok

  defp delete_devices(session, api, ids, password) do
    Matrx.Crypto.UIA.with_password(
      session,
      %{"devices" => ids},
      password,
      &api.delete_devices(session, &1)
    )
  end

  defp reset_cross_signing(_session, _api, _password, false), do: :ok

  defp reset_cross_signing(session, api, password, true) do
    opts = [api: api, reset: true] ++ if(password, do: [password: password], else: [])
    Matrx.Crypto.CrossSigning.bootstrap(session, opts)
  end

  @doc "Send a text message, encrypting it if the room is encrypted"
  @spec say(Session.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def say(session, room_id, text, opts \\ []) do
    Room.send_event(
      room_id,
      session,
      "m.room.message",
      %{"msgtype" => "m.text", "body" => text},
      Keyword.take(opts, [:api])
    )
  end

  @doc "Rooms the client knows about, with whether each is encrypted"
  @spec rooms() :: [%{room_id: String.t(), encrypted: boolean(), members: [String.t()]}]
  def rooms do
    for {room_id, _pid, _} <-
          Registry.select(Matrx.RoomRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2", :_}}]}]) do
      case Room.encryption_info(room_id) do
        {:ok, %{members: members}} -> %{room_id: room_id, encrypted: true, members: members}
        :error -> %{room_id: room_id, encrypted: false, members: []}
      end
    end
  end

  @doc """
  Print every event of a room as it arrives, from a background process.
  Returns the pid; `Process.exit(pid, :kill)` stops it.
  """
  @spec watch(String.t()) :: pid()
  def watch(room_id) do
    parent_gl = Process.group_leader()

    spawn(fn ->
      Process.group_leader(self(), parent_gl)
      Room.subscribe(room_id)
      watch_loop(room_id)
    end)
  end

  defp watch_loop(room_id) do
    receive do
      %Matrx.API.Event{} = event ->
        IO.puts(format(room_id, event))
        watch_loop(room_id)
    end
  end

  @doc false
  def format(_room_id, %{type: "m.room.message", sender: sender, content: %{body: body}}),
    do: "#{sender}: #{body}"

  def format(_room_id, %{type: "m.room.encrypted", sender: sender, event_id: id}),
    do: "#{sender}: [waiting for the room key] #{id}"

  def format(_room_id, %{type: type, sender: sender}), do: "#{sender}: <#{type}>"

  defp login(uri, username, opts) do
    password = Keyword.get(opts, :password) || System.get_env("MATRIX_PASSWORD")

    case Session.restore_or_login(uri, username, password, opts) do
      {:ok, session} ->
        session

      {:error, :password_required} ->
        raise ArgumentError, "pass `password:` or set MATRIX_PASSWORD"

      {:error, reason} ->
        raise "login failed: #{inspect(reason)}"
    end
  end

  defp migrate, do: Repo.migrate()
end
