defmodule Matrx.API do
  @behaviour Matrx.APIBehaviour

  @impl Matrx.APIBehaviour
  def register(session, payload) do
    case Req.post(url(session, ["_matrix", "client", "v3", "register"]), json: payload) do
      {:ok, %{status: 200, body: body}} ->
        login_ok(body)

      {:ok, %{status: 401, body: %{"session" => session_challenge}}} ->
        new_payload =
          Map.merge(payload, %{
            auth: %{
              type: "m.login.dummy",
              session: session_challenge
            }
          })

        register(session, new_payload)

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @impl Matrx.APIBehaviour
  def login_password(session, identifier, password, opts \\ []) do
    payload =
      %{
        type: "m.login.password",
        identifier: identifier,
        password: password
      }
      |> then(fn payload ->
        case Keyword.get(opts, :device_id) do
          nil -> payload
          device_id -> Map.put(payload, :device_id, device_id)
        end
      end)

    case Req.post(url(session, ["_matrix", "client", "v3", "login"]), json: payload) do
      {:ok, %{status: 200, body: body}} ->
        login_ok(body)

      {:ok, %{status: 403, body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  defp login_ok(%{
         "access_token" => access_token,
         "device_id" => device_id,
         "home_server" => home_server,
         "user_id" => user_id
       }) do
    {:ok,
     %{
       access_token: access_token,
       device_id: device_id,
       home_server: home_server,
       user_id: user_id
     }}
  end

  def whoami(session) do
    case Req.get(url(session, ["_matrix", "client", "v3", "account", "whoami"]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200, body: %{"user_id" => user_id, "device_id" => device_id}}} ->
        {:ok, %{user_id: user_id, device_id: device_id}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def create_room(session, payload) do
    case Req.post(url(session, ["_matrix", "client", "v3", "createRoom"]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200, body: %{"room_id" => room_id}}} ->
        {:ok, %{room_id: room_id}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @impl Matrx.APIBehaviour
  def join_room(session, room_id) do
    case Req.post(url(session, ["_matrix", "client", "v3", "rooms", room_id, "join"]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @impl Matrx.APIBehaviour
  def leave_room(session, room_id) do
    case Req.post(url(session, ["_matrix", "client", "v3", "rooms", room_id, "leave"]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @impl Matrx.APIBehaviour
  def kick_room(session, room_id, payload) do
    case Req.post(url(session, ["_matrix", "client", "v3", "rooms", room_id, "kick"]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  # @impl Matrx.APIBehaviour
  def send_room_message(session, room_id, transaction_id, type, message) do
    case Req.put(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "rooms",
             room_id,
             "send",
             type,
             transaction_id
           ]),
           headers: headers(session),
           json: message
         ) do
      {:ok, %{status: 200, body: %{"event_id" => event_id}}} ->
        {:ok, %{event_id: event_id}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upload `data` to the media repository. Returns the `mxc://` URI.
  """
  @impl Matrx.APIBehaviour
  def upload_media(session, data, content_type, filename \\ nil) do
    query = if filename, do: [filename: filename]

    case Req.post(url(session, ["_matrix", "media", "v3", "upload"], query),
           headers: [{"content-type", content_type} | headers(session)],
           body: data,
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200, body: %{"content_uri" => content_uri}}} ->
        {:ok, %{content_uri: content_uri}}

      {:ok, %{body: %{"errcode" => _} = body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `message` may carry a `"type"`, which is the event type and not part of the body
  def send_to_device(session, transaction_id, message) do
    {type, message} = Map.pop(message, "type", "m.room.encrypted")

    case Req.put(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "sendToDevice",
             type,
             transaction_id
           ]),
           headers: headers(session),
           json: message
         ) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def upload_keys(session, keys) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "keys",
             "upload"
           ]),
           headers: headers(session),
           json: keys
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Matrx.API.OneTimeKeyCounts.from_response(body)}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def keys_query(session, query) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "keys",
             "query"
           ]),
           headers: headers(session),
           json: query
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Matrx.API.DeviceKeys.from_response(body)}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @doc """
  Upload cross-signing keys. Servers may answer with a user-interactive auth
  challenge, returned as `{:error, {:uia_required, auth_session}}`.
  """
  def upload_signing_keys(session, body) do
    case Req.post(
           url(session, ["_matrix", "client", "v3", "keys", "device_signing", "upload"]),
           headers: headers(session),
           json: body
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401, body: %{"session" => uia_session, "flows" => _}}} ->
        {:error, {:uia_required, uia_session}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @doc "Upload signatures of keys and devices. Returns the `failures` of the response."
  def upload_signatures(session, body) do
    case Req.post(
           url(session, ["_matrix", "client", "v3", "keys", "signatures", "upload"]),
           headers: headers(session),
           json: body
         ) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response["failures"] || %{}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  @doc "The devices of our account, as the server lists them"
  def list_devices(session) do
    case Req.get(url(session, ["_matrix", "client", "v3", "devices"]), headers: headers(session)) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} -> {:ok, devices}
      {:ok, %{body: body}} -> {:error, Matrx.APIError.from_json(body)}
    end
  end

  @doc """
  Delete devices. Servers ask for the account password, returned as
  `{:error, {:uia_required, auth_session}}`.
  """
  def delete_devices(session, body) do
    case Req.post(url(session, ["_matrix", "client", "v3", "delete_devices"]),
           headers: headers(session),
           json: body
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401, body: %{"session" => uia_session, "flows" => _}}} ->
        {:error, {:uia_required, uia_session}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def claim_keys(session, claim) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "keys",
             "claim"
           ]),
           headers: headers(session),
           json: claim
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Matrx.API.ClaimKeys.from_response(body)}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def device_signing_upload(session, payload, identifier, password) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "keys",
             "device_signing",
             "upload"
           ]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401, body: %{"session" => session_challenge}}} ->
        new_payload =
          Map.merge(payload, %{
            auth: %{
              type: "m.login.password",
              identifier: identifier,
              password: password,
              session: session_challenge
            }
          })

        device_signing_upload(session, new_payload, identifier, password)

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def signatures_upload(session, payload) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "keys",
             "signatures",
             "upload"
           ]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def devices(session) do
    case Req.get(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "devices"
           ]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Matrx.API.Devices.from_response(body)}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def delete_devices(session, payload, identifier, password) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "delete_devices"
           ]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 401, body: %{"session" => session_challenge}}} ->
        new_payload =
          Map.merge(payload, %{
            auth: %{
              type: "m.login.password",
              identifier: identifier,
              password: password,
              session: session_challenge
            }
          })

        delete_devices(session, new_payload, identifier, password)

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def user_directory_search(session, payload) do
    case Req.post(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "user_directory",
             "search"
           ]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  def sync(session, query \\ nil) do
    case Req.get(
           url(
             session,
             [
               "_matrix",
               "client",
               "v3",
               "sync"
             ],
             query
           ),
           headers: headers(session),
           receive_timeout: sync_timeout(query[:timeout])
         ) do
      {:ok, %{status: 200, body: body}} ->
        # IO.inspect(body, label: "sync")
        {:ok, Matrx.API.Sync.from_response(body)}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}
    end
  end

  defp sync_timeout(nil), do: :timer.seconds(5)
  defp sync_timeout(timeout), do: timeout + :timer.seconds(5)

  defp url(session, path, query \\ nil) do
    base = %{session.home_server_uri | path: "/" <> Enum.join(path, "/")}

    if query do
      %{base | query: URI.encode_query(query)}
    else
      base
    end
  end

  defp headers(session) do
    [{"Authorization", "Bearer " <> session.access_token}]
  end
end
