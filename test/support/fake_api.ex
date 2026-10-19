defmodule Matrx.Support.FakeAPI do
  @moduledoc """
  In-memory stand-in for `Matrx.API`.

  A "homeserver" is a `Feed` process. Sessions find it either through a
  `%{feed: pid}` map or by `home_server_uri.host`, which is registered when the
  feed is started with `host:`.

  * `sync/2` blocks until a response is pushed with `push_sync/2`, like a long poll.
  * Calls are served from memory and implement `Matrx.APIBehaviour`. Calls that
    send something are forwarded to the process that started the feed, e.g.
    `{:send_room_message, room_id, type, content}`, `{:upload_media, data, type, filename}`,
    `{:join_room, user_id, room_id}`, `{:create_room, user_id, payload}`,
    `{:leave_room, user_id, room_id}`, `{:kick_room, user_id, room_id, payload}`.
  """

  @behaviour Matrx.APIBehaviour

  @registry Matrx.Support.FakeAPI.Registry

  defmodule Feed do
    use GenServer

    def start_link({owner, host}) do
      name =
        if host, do: [name: {:via, Registry, {Matrx.Support.FakeAPI.Registry, host}}], else: []

      GenServer.start_link(__MODULE__, owner, name)
    end

    @impl true
    def init(owner),
      do:
        {:ok,
         %{
           owner: owner,
           queue: :queue.new(),
           waiter: nil,
           otks: 0,
           claimable: %{},
           device_keys: %{},
           signing_keys: %{},
           uia_password: nil,
           failures: %{},
           profiles: %{}
         }}

    @impl true
    def handle_call(:poll, from, state) do
      case :queue.out(state.queue) do
        {{:value, sync}, queue} -> {:reply, sync, %{state | queue: queue}}
        {:empty, _} -> {:noreply, %{state | waiter: from}}
      end
    end

    def handle_call({:upload_keys, body, user_id, device_id}, _from, state) do
      send(state.owner, {:upload_keys, body})
      otks = state.otks + map_size(body["one_time_keys"] || %{})
      state = %{state | otks: otks}

      state =
        if user_id && body["device_keys"] do
          device_keys =
            Map.update(
              state.device_keys,
              user_id,
              %{device_id => body["device_keys"]},
              &Map.put(&1, device_id, body["device_keys"])
            )

          %{state | device_keys: device_keys}
        else
          state
        end

      state =
        if user_id do
          claimable =
            Map.merge(
              Map.get(state.claimable, {user_id, device_id}, %{}),
              body["one_time_keys"] || %{}
            )

          %{state | claimable: Map.put(state.claimable, {user_id, device_id}, claimable)}
        else
          state
        end

      {:reply, otks, state}
    end

    def handle_call({:claim_keys, requested}, _from, state) do
      {claimed, claimable} =
        Enum.reduce(requested, {%{}, state.claimable}, fn {user_id, devices}, acc ->
          Enum.reduce(devices, acc, fn {device_id, _algorithm}, {claimed, claimable} ->
            case Map.get(claimable, {user_id, device_id}, %{}) |> Enum.take(1) do
              [{key_id, object}] ->
                remaining = Map.delete(claimable[{user_id, device_id}], key_id)

                {put_in(claimed, [Access.key(user_id, %{}), Access.key(device_id)], %{
                   key_id => object
                 }), Map.put(claimable, {user_id, device_id}, remaining)}

              [] ->
                {claimed, claimable}
            end
          end)
        end)

      {:reply, %{"one_time_keys" => claimed, "failures" => %{}}, %{state | claimable: claimable}}
    end

    def handle_call({:send_to_device, type, messages}, _from, state) do
      send(state.owner, {:send_to_device, messages})
      send(state.owner, {:send_to_device, type, messages})
      {:reply, :ok, state}
    end

    def handle_call({:send_room_message, room_id, type, content}, _from, state) do
      send(state.owner, {:send_room_message, room_id, type, content})
      {:reply, "$sent#{System.unique_integer([:positive])}", state}
    end

    def handle_call({:notify, message}, _from, state) do
      send(state.owner, message)
      {:reply, :ok, state}
    end

    def handle_call({:get_profile, user_id}, _from, state) do
      {:reply, {:ok, Map.get(state.profiles, user_id, %{})}, state}
    end

    def handle_call({:put_profile, user_id, field, value}, _from, state) do
      profile = Map.get(state.profiles, user_id, %{}) |> Map.put(field, value)
      send(state.owner, {:put_profile, user_id, field, value})
      {:reply, :ok, %{state | profiles: Map.put(state.profiles, user_id, profile)}}
    end

    def handle_call({:upload_media, data, content_type, filename}, _from, state) do
      send(state.owner, {:upload_media, data, content_type, filename})

      {:reply,
       {:ok, %{content_uri: "mxc://fake.example/media#{System.unique_integer([:positive])}"}},
       state}
    end

    def handle_call({:keys_query, requested}, _from, state) do
      users = Map.keys(requested)
      found = Map.take(state.device_keys, users)

      response =
        for kind <- ["master_keys", "self_signing_keys", "user_signing_keys"],
            into: %{"device_keys" => found, "failures" => state.failures} do
          {kind,
           for(
             user <- users,
             object = get_in(state.signing_keys, [user, kind]),
             into: %{},
             do: {user, object}
           )}
        end

      {:reply, response, state}
    end

    def handle_call({:require_uia, password}, _from, state),
      do: {:reply, :ok, %{state | uia_password: password}}

    def handle_call({:upload_signing_keys, user_id, body}, _from, state) do
      auth = body["auth"]

      cond do
        state.uia_password == nil or
            (is_map(auth) and auth["password"] == state.uia_password and auth["session"] == "uia") ->
          keys = %{
            "master_keys" => body["master_key"],
            "self_signing_keys" => body["self_signing_key"],
            "user_signing_keys" => body["user_signing_key"]
          }

          send(state.owner, {:upload_signing_keys, user_id, body})
          {:reply, :ok, put_in(state.signing_keys[user_id], keys)}

        is_map(auth) ->
          {:reply, {:error, :forbidden}, state}

        true ->
          {:reply, {:error, {:uia_required, "uia"}}, state}
      end
    end

    def handle_call({:list_devices, user_id}, _from, state) do
      ids = Map.keys(Map.get(state.device_keys, user_id, %{}))
      {:reply, Enum.map(ids, &%{"device_id" => &1, "user_id" => user_id}), state}
    end

    def handle_call({:delete_devices, user_id, body}, _from, state) do
      auth = body["auth"]

      cond do
        state.uia_password == nil or
            (is_map(auth) and auth["password"] == state.uia_password and auth["session"] == "uia") ->
          device_keys =
            update_in(state.device_keys, [user_id], &Map.drop(&1 || %{}, body["devices"]))

          send(state.owner, {:delete_devices, user_id, body["devices"]})
          {:reply, :ok, %{state | device_keys: device_keys}}

        is_map(auth) ->
          {:reply, {:error, :forbidden}, state}

        true ->
          {:reply, {:error, {:uia_required, "uia"}}, state}
      end
    end

    def handle_call({:upload_signatures, body}, _from, state) do
      send(state.owner, {:upload_signatures, body})

      device_keys =
        Enum.reduce(body, state.device_keys, fn {user_id, devices}, acc ->
          Enum.reduce(devices, acc, fn {device_id, signed}, acc ->
            case get_in(acc, [user_id, device_id]) do
              nil ->
                acc

              stored ->
                merged =
                  Map.update(stored, "signatures", signed["signatures"], fn sigs ->
                    Map.merge(sigs, signed["signatures"], fn _, a, b -> Map.merge(a, b) end)
                  end)

                put_in(acc, [user_id, device_id], merged)
            end
          end)
        end)

      {:reply, :ok, %{state | device_keys: device_keys}}
    end

    def handle_call({:put_device, user_id, device_id, device}, _from, state) do
      device_keys =
        Map.update(
          state.device_keys,
          user_id,
          %{device_id => device},
          &Map.put(&1, device_id, device)
        )

      {:reply, :ok, %{state | device_keys: device_keys}}
    end

    def handle_call({:delete_device, user_id, device_id}, _from, state) do
      {:reply, :ok,
       %{
         state
         | device_keys: update_in(state.device_keys, [user_id], &Map.delete(&1 || %{}, device_id))
       }}
    end

    def handle_call({:set_failures, failures}, _from, state) do
      {:reply, :ok, %{state | failures: failures}}
    end

    @impl true
    def handle_cast({:push, sync}, %{waiter: nil} = state) do
      {:noreply, %{state | queue: :queue.in(sync, state.queue)}}
    end

    def handle_cast({:push, sync}, %{waiter: {pid, _} = waiter} = state) do
      if Process.alive?(pid) do
        GenServer.reply(waiter, sync)
        {:noreply, %{state | waiter: nil}}
      else
        {:noreply, %{state | waiter: nil, queue: :queue.in(sync, state.queue)}}
      end
    end
  end

  @doc "Start a fake homeserver owned by the calling process"
  def start_feed(opts \\ []) do
    Feed.start_link({self(), Keyword.get(opts, :host)})
  end

  @doc "Queue a raw (string keyed) `/sync` response body"
  def push_sync(feed, body) when is_map(body) do
    GenServer.cast(feed, {:push, Matrx.API.Sync.from_response(body)})
  end

  @impl Matrx.APIBehaviour
  def sync(session, query) do
    :ok = GenServer.call(feed(session), {:notify, {:sync_query, query}})
    {:ok, GenServer.call(feed(session), :poll, :infinity)}
  end

  @impl Matrx.APIBehaviour
  def upload_keys(session, body) do
    count =
      GenServer.call(
        feed(session),
        {:upload_keys, body, Map.get(session, :user_id), Map.get(session, :device_id)}
      )

    {:ok,
     Matrx.API.OneTimeKeyCounts.from_response(%{
       "one_time_key_counts" => %{"signed_curve25519" => count}
     })}
  end

  @doc "Make `/keys/query` report this (raw, signed) device object for a user"
  def put_device(feed, user_id, device_id, device),
    do: GenServer.call(feed, {:put_device, user_id, device_id, device})

  def delete_device(feed, user_id, device_id),
    do: GenServer.call(feed, {:delete_device, user_id, device_id})

  @doc "Make `/keys/query` report failures, e.g. `%{\"other.example\" => %{}}`"
  def set_failures(feed, failures), do: GenServer.call(feed, {:set_failures, failures})

  @doc "Make `/keys/device_signing/upload` ask for the password, as a real server does"
  def require_uia(feed, password), do: GenServer.call(feed, {:require_uia, password})

  @impl Matrx.APIBehaviour
  def upload_signing_keys(session, body),
    do: GenServer.call(feed(session), {:upload_signing_keys, session.user_id, body})

  @impl Matrx.APIBehaviour
  def whoami(session) do
    {:ok, devices} = list_devices(session)

    if Enum.any?(devices, &(&1["device_id"] == session.device_id)) do
      {:ok, %{user_id: session.user_id, device_id: session.device_id}}
    else
      {:error, %Matrx.APIError{errcode: :m_unknown_token, error: "Unknown token"}}
    end
  end

  @impl Matrx.APIBehaviour
  def list_devices(session),
    do: {:ok, GenServer.call(feed(session), {:list_devices, session.user_id})}

  @impl Matrx.APIBehaviour
  def delete_devices(session, body),
    do: GenServer.call(feed(session), {:delete_devices, session.user_id, body})

  @impl Matrx.APIBehaviour
  def upload_signatures(session, body) do
    :ok = GenServer.call(feed(session), {:upload_signatures, body})
    {:ok, %{}}
  end

  @impl Matrx.APIBehaviour
  def upload_media(session, data, content_type, filename \\ nil),
    do: GenServer.call(feed(session), {:upload_media, data, content_type, filename})

  @impl Matrx.APIBehaviour
  def keys_query(session, %{"device_keys" => requested}) do
    {:ok,
     Matrx.API.DeviceKeys.from_response(GenServer.call(feed(session), {:keys_query, requested}))}
  end

  @impl Matrx.APIBehaviour
  def claim_keys(session, %{"one_time_keys" => requested}) do
    {:ok,
     Matrx.API.ClaimKeys.from_response(GenServer.call(feed(session), {:claim_keys, requested}))}
  end

  @impl Matrx.APIBehaviour
  def send_to_device(session, _transaction_id, %{"messages" => messages} = body) do
    type = Map.get(body, "type", "m.room.encrypted")
    :ok = GenServer.call(feed(session), {:send_to_device, type, messages})
    {:ok, %{}}
  end

  @impl Matrx.APIBehaviour
  def send_room_message(session, room_id, _transaction_id, type, content) do
    event_id = GenServer.call(feed(session), {:send_room_message, room_id, type, content})
    {:ok, %{event_id: event_id}}
  end

  @impl Matrx.APIBehaviour
  def register(session, %{username: username} = payload) do
    {:ok, login(session, username, Map.get(payload, :device_id))}
  end

  @impl Matrx.APIBehaviour
  def login_password(session, %{user: username}, _password, opts \\ []) do
    {:ok, login(session, username, Keyword.get(opts, :device_id))}
  end

  @impl Matrx.APIBehaviour
  def create_room(session, payload) do
    room_id = "!room#{System.unique_integer([:positive])}:#{session.home_server_uri.host}"
    :ok = notify(session, {:create_room, session.user_id, payload})
    {:ok, %{room_id: room_id}}
  end

  @impl Matrx.APIBehaviour
  def join_room(session, room_id), do: notify(session, {:join_room, session.user_id, room_id})

  @impl Matrx.APIBehaviour
  def leave_room(session, room_id), do: notify(session, {:leave_room, session.user_id, room_id})

  @impl Matrx.APIBehaviour
  def kick_room(session, room_id, payload),
    do: notify(session, {:kick_room, session.user_id, room_id, payload})

  @impl Matrx.APIBehaviour
  def user_directory_search(session, payload) do
    :ok = notify(session, {:user_directory_search, payload})
    {:ok, %{"results" => [], "limited" => false}}
  end

  defp notify(session, message), do: GenServer.call(feed(session), {:notify, message})

  @impl Matrx.APIBehaviour
  def get_profile(session, user_id),
    do: GenServer.call(feed(session), {:get_profile, user_id})

  @impl Matrx.APIBehaviour
  def set_display_name(session, name),
    do: GenServer.call(feed(session), {:put_profile, session.user_id, "displayname", name})

  @impl Matrx.APIBehaviour
  def set_avatar_url(session, uri),
    do: GenServer.call(feed(session), {:put_profile, session.user_id, "avatar_url", uri})

  defp login(%{home_server_uri: %URI{host: host}}, username, device_id) do
    %{
      access_token: "token_#{System.unique_integer([:positive])}",
      device_id: device_id || "DEVICE#{System.unique_integer([:positive])}",
      home_server: host,
      user_id: "@#{username}:#{host}"
    }
  end

  defp feed(%{feed: feed}), do: feed

  defp feed(%{home_server_uri: %URI{host: host}}) do
    [{pid, _}] = Registry.lookup(@registry, host)
    pid
  end
end
