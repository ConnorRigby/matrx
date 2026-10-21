defmodule Matrx.API do
  @moduledoc """
  Matrix HTTP API calls.

  Rate-limited requests (`M_LIMIT_EXCEEDED` or HTTP 429) are retried up to
  three times, including POSTs and uploads. `Retry-After` takes precedence over
  `retry_after_ms`; without either, retries use exponential backoff starting
  at one second. Retries reuse the original body and transaction ID.

      config :matrx, Matrx.API, max_retries: 3

  Set `max_retries: 0` to disable retries. Exhausted requests return the normal
  API error, including `retry_after_ms` when supplied by the homeserver.
  Req's existing transient-error retries for GET/HEAD requests are preserved.
  Other POST/PUT failures are not retried.
  """

  @behaviour Matrx.APIBehaviour

  @impl Matrx.APIBehaviour
  def register(session, payload) do
    case request(:post, url(session, ["_matrix", "client", "v3", "register"]), json: payload) do
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

      {:error, reason} ->
        {:error, reason}
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

    case request(:post, url(session, ["_matrix", "client", "v3", "login"]), json: payload) do
      {:ok, %{status: 200, body: body}} ->
        login_ok(body)

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
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

  @impl Matrx.APIBehaviour
  def whoami(session) do
    case request(:get, url(session, ["_matrix", "client", "v3", "account", "whoami"]),
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
    case request(:post, url(session, ["_matrix", "client", "v3", "createRoom"]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200, body: %{"room_id" => room_id}}} ->
        {:ok, %{room_id: room_id}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def join_room(session, room_id) do
    case request(:post, url(session, ["_matrix", "client", "v3", "rooms", room_id, "join"]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def leave_room(session, room_id) do
    case request(:post, url(session, ["_matrix", "client", "v3", "rooms", room_id, "leave"]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def kick_room(session, room_id, payload) do
    case request(:post, url(session, ["_matrix", "client", "v3", "rooms", room_id, "kick"]),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def send_room_message(session, room_id, transaction_id, type, message) do
    case request(
           :put,
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

    case request(:post, url(session, ["_matrix", "media", "v3", "upload"], query),
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
  @impl Matrx.APIBehaviour
  def send_to_device(session, transaction_id, message) do
    {type, message} = Map.pop(message, "type", "m.room.encrypted")

    case request(
           :put,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def upload_keys(session, keys) do
    case request(
           :post,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def keys_query(session, query) do
    case request(
           :post,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upload cross-signing keys. Servers may answer with a user-interactive auth
  challenge, returned as `{:error, {:uia_required, auth_session}}`.
  """
  @impl Matrx.APIBehaviour
  def upload_signing_keys(session, body) do
    case request(
           :post,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Upload signatures of keys and devices. Returns the `failures` of the response."
  @impl Matrx.APIBehaviour
  def upload_signatures(session, body) do
    case request(
           :post,
           url(session, ["_matrix", "client", "v3", "keys", "signatures", "upload"]),
           headers: headers(session),
           json: body
         ) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response["failures"] || %{}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The devices of our account, as the server lists them"
  @impl Matrx.APIBehaviour
  def list_devices(session) do
    case request(:get, url(session, ["_matrix", "client", "v3", "devices"]),
           headers: headers(session)
         ) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} -> {:ok, devices}
      {:ok, %{body: body}} -> {:error, Matrx.APIError.from_json(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete devices. Servers ask for the account password, returned as
  `{:error, {:uia_required, auth_session}}`.
  """
  @impl Matrx.APIBehaviour
  def delete_devices(session, body) do
    case request(:post, url(session, ["_matrix", "client", "v3", "delete_devices"]),
           headers: headers(session),
           json: body
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401, body: %{"session" => uia_session, "flows" => _}}} ->
        {:error, {:uia_required, uia_session}}

      {:ok, %{body: body}} ->
        {:error, Matrx.APIError.from_json(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def claim_keys(session, claim) do
    case request(
           :post,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def user_directory_search(session, payload) do
    case request(
           :post,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Matrx.APIBehaviour
  def sync(session, query \\ nil) do
    case request(
           :get,
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_timeout(nil), do: :timer.seconds(5)
  defp sync_timeout(timeout), do: timeout + :timer.seconds(5)

  @doc "Fetch a user's profile, including string-keyed displayname and avatar_url fields."
  @impl Matrx.APIBehaviour
  def get_profile(session, user_id) do
    case request(:get, profile_url(session, user_id), headers: headers(session)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, Matrx.APIError.from_json(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Set the logged-in user's display name. An empty string clears it."
  @impl Matrx.APIBehaviour
  def set_display_name(session, name), do: put_profile(session, "displayname", name)

  @doc "Set the logged-in user's avatar to an mxc:// URI. An empty string clears it."
  @impl Matrx.APIBehaviour
  def set_avatar_url(session, uri), do: put_profile(session, "avatar_url", uri)

  defp put_profile(session, field, value) do
    case request(:put, profile_url(session, session.user_id, [field]),
           headers: headers(session),
           json: %{field => value}
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, Matrx.APIError.from_json(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp profile_url(session, user_id, suffix \\ []) do
    encoded_user = URI.encode(user_id, &URI.char_unreserved?/1)
    url(session, ["_matrix", "client", "v3", "profile", encoded_user] ++ suffix)
  end

  @doc "Fetch a user's presence as a string-keyed content map."
  @impl Matrx.APIBehaviour
  def get_presence(session, user_id) do
    case request(:get, presence_url(session, user_id), headers: headers(session)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{body: body}} -> {:error, Matrx.APIError.from_json(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Set the logged-in user's presence using a string-keyed payload."
  @impl Matrx.APIBehaviour
  def set_presence(session, payload) do
    case request(:put, presence_url(session, session.user_id),
           headers: headers(session),
           json: payload
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, Matrx.APIError.from_json(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp presence_url(session, user_id) do
    encoded_user = URI.encode(user_id, &URI.char_unreserved?/1)
    url(session, ["_matrix", "client", "v3", "presence", encoded_user, "status"])
  end

  defp request(method, url, opts) do
    config = Application.get_env(:matrx, __MODULE__, [])

    Req.request(
      Keyword.merge(opts,
        method: method,
        url: url,
        retry: &retry/2,
        max_retries: Keyword.get(config, :max_retries, 3)
      )
    )
  end

  defp retry(request, %Req.Response{} = response) do
    body = retry_body(response.body)

    if response.status == 429 or match?(%{"errcode" => "M_LIMIT_EXCEEDED"}, body) do
      delay =
        retry_after(response) || retry_after_ms(body) ||
          Integer.pow(2, Req.Request.get_private(request, :req_retry_count, 0)) * 1000

      {:delay, delay}
    else
      transient_retry?(request, response)
    end
  end

  defp retry(request, exception), do: transient_retry?(request, exception)

  # Preserve Req's default :safe_transient policy outside Matrix rate limits.
  defp transient_retry?(%{method: method}, result) when method in [:get, :head] do
    case result do
      %Req.Response{status: status} ->
        status in [408, 500, 502, 503, 504]

      %Req.TransportError{reason: reason} ->
        reason in [:timeout, :econnrefused, :closed]

      %Req.HTTPError{protocol: :http2, reason: reason} ->
        reason in [:unprocessed, :pool_not_available]

      _ ->
        false
    end
  end

  defp transient_retry?(_request, _result), do: false

  # Req runs its retry step before decoding JSON response bodies.
  defp retry_body(body) when is_binary(body) do
    :json.decode(body)
  rescue
    ErlangError -> nil
  end

  defp retry_body(body), do: body

  defp retry_after_ms(%{"retry_after_ms" => delay}) when is_integer(delay) and delay >= 0,
    do: delay

  defp retry_after_ms(_body), do: nil

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> :timer.seconds(seconds)
          :error -> Req.Response.get_retry_after(response)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    # An invalid header should fall back to the Matrix delay or backoff.
    _ in [ArgumentError, MatchError, FunctionClauseError] -> nil
  end

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
