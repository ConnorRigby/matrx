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
  def login_password(session, identifier, password) do
    payload = %{
      type: "m.login.password",
      identifier: identifier,
      password: password
    }

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
    end
  end

  def send_to_device(session, transaction_id, message) do
    case Req.put(
           url(session, [
             "_matrix",
             "client",
             "v3",
             "sendToDevice",
             "m.room.encrypted",
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
