defmodule Matrx.APIBehaviour do
  @moduledoc """
  The homeserver calls the library makes. `Matrx.API` talks to a real server and
  `Matrx.Support.FakeAPI` (in the test support code) is the in-memory stand-in.
  Everything that calls the server takes an `:api` option to swap the module.

  Calls that run before a device exists (`register/2` and `login_password/4`)
  take `t:anonymous_session/0`, which is just the homeserver. All others take a
  `Matrx.Session`.
  """

  alias Matrx.API.{ClaimKeys, DeviceKeys, OneTimeKeyCounts, Sync}

  @type session :: Matrx.Session.t()
  @type anonymous_session :: %{
          required(:home_server_uri) => URI.t(),
          optional(:access_token) => nil,
          optional(atom()) => term()
        }

  @type login_ok() :: %{
          access_token: String.t(),
          device_id: String.t(),
          home_server: String.t(),
          user_id: String.t()
        }
  @type register_payload() :: %{
          required(:username) => String.t(),
          required(:password) => String.t(),
          optional(:device_id) => String.t(),
          optional(:device_display_name) => String.t()
        }
  @type login_identifier :: %{required(:type) => String.t(), required(:user) => String.t()}
  @type login_opts :: [device_id: String.t()]

  @type transaction_id :: String.t()
  @type room_id :: String.t()
  @type user_id() :: String.t()
  @type device_id() :: String.t()
  @type event_id() :: String.t()
  @type event_type() :: String.t()
  @type mxc_uri() :: String.t()

  @typedoc "An error answered by the homeserver"
  @type standard_api_error :: {:error, Matrx.APIError.t()}

  @typedoc """
  Servers answer with a user-interactive auth challenge when an action needs the
  account password. The string is the `session` to send back in `auth`.
  """
  @type uia_error :: {:error, {:uia_required, auth_session :: String.t()}}

  @typedoc "Failures talking to the server at all, e.g. a closed connection"
  @type transport_error :: {:error, Exception.t() | term()}

  @type creation_content() :: map()
  @type state_event() :: %{
          content: map(),
          state_key: String.t(),
          type: String.t()
        }
  @type invite_3pid() :: %{
          address: String.t(),
          id_access_token: String.t(),
          id_server: String.t(),
          medium: String.t()
        }
  @type room_preset() :: :private_chat | :public_chat | :trusted_private_chat
  @type room_visibility() :: :public | :private
  @type room() :: %{room_id: room_id()}
  @type power_level_content_override() :: map()

  @type create_room_payload() :: %{
          optional(:creation_content) => creation_content(),
          optional(:initial_state) => [state_event()],
          optional(:invite) => [user_id()],
          optional(:invite_3pid) => [invite_3pid],
          optional(:is_direct) => boolean(),
          optional(:name) => String.t(),
          optional(:power_level_content_override) => power_level_content_override(),
          optional(:preset) => room_preset(),
          optional(:room_alias_name) => String.t(),
          optional(:room_version) => String.t(),
          optional(:topic) => String.t(),
          optional(:visibility) => room_visibility()
        }

  @type kick_room_payload :: %{
          required(:user_id) => user_id(),
          optional(:reason) => String.t()
        }

  @typedoc "Event content as sent: string keyed, JSON encodable"
  @type content :: %{optional(String.t()) => term()}

  @typedoc "`since` and `timeout` (milliseconds) of a sync request. Nil is an initial sync."
  @type sync_query ::
          nil
          | %{
              optional(:since) => String.t(),
              optional(:timeout) => integer(),
              optional(:full_state) => boolean()
            }

  @typedoc """
  The body of `/sendToDevice`: `\"messages\"` is `{user_id => {device_id => content}}`.
  A `\"type\"` next to it is the event type, `m.room.encrypted` by default.
  """
  @type to_device_body :: %{required(String.t()) => term()}

  @typedoc "`{usage => key object}` bodies of `/keys/device_signing/upload`, plus an optional `\"auth\"`"
  @type signing_keys_body :: %{optional(String.t()) => map()}

  @typedoc "`{user_id => {key_id => signed key or device object}}`"
  @type signatures_body :: %{optional(user_id()) => %{optional(String.t()) => map()}}

  @typedoc "`{user_id => {key_id => failure}}`, empty when everything was accepted"
  @type signature_failures :: %{optional(user_id()) => map()}

  @typedoc "A device of our account as the server lists it, string keyed"
  @type device_info :: %{required(String.t()) => term()}

  @type whoami :: %{user_id: user_id(), device_id: device_id()}

  @doc """
  Log in with a password. `identifier` is the user, e.g.
  `%{type: "m.id.user", user: "alice"}`. The `:device_id` option asks for that
  device id instead of a generated one.

  ```elixir
  iex> Matrx.API.login_password(%{home_server_uri: URI.parse("http://localhost:8008")}, %{type: "m.id.user", user: username}, password)
  {:ok, %{access_token: "...", device_id: "EGHMKVZZCA",
     home_server: "matrix.pressy4pie.dev",
     user_id: "@username:matrix.pressy4pie.dev"
  }}
  ```
  """
  @callback login_password(
              anonymous_session,
              login_identifier,
              password :: String.t(),
              login_opts
            ) :: {:ok, login_ok} | standard_api_error() | transport_error()

  @callback register(anonymous_session, register_payload) ::
              {:ok, login_ok()} | standard_api_error() | transport_error()

  @doc "The user and device the session's access token belongs to. A dead token is `:m_unknown_token`."
  @callback whoami(session) :: {:ok, whoami} | standard_api_error() | transport_error()

  @callback create_room(session, create_room_payload) ::
              {:ok, room()} | standard_api_error() | transport_error()

  @doc "Join by room id or alias"
  @callback join_room(session, room_id | String.t()) ::
              :ok | standard_api_error() | transport_error()
  @callback leave_room(session, room_id) :: :ok | standard_api_error() | transport_error()
  @callback kick_room(session, room_id, kick_room_payload) ::
              :ok | standard_api_error() | transport_error()

  @callback send_room_message(session, room_id, transaction_id, event_type, content) ::
              {:ok, %{event_id: event_id()}} | standard_api_error() | transport_error()

  @doc "Upload to the media repository. The filename is optional."
  @callback upload_media(
              session,
              data :: binary(),
              content_type :: String.t(),
              filename :: String.t() | nil
            ) ::
              {:ok, %{content_uri: mxc_uri()}}
              | standard_api_error()
              | {:error, {:http_status, non_neg_integer(), term()}}
              | transport_error()

  @callback send_to_device(session, transaction_id, to_device_body) ::
              {:ok, map()} | standard_api_error() | transport_error()

  @callback upload_keys(session, body :: map()) ::
              {:ok, OneTimeKeyCounts.t()} | standard_api_error() | transport_error()
  @callback keys_query(session, query :: map()) ::
              {:ok, DeviceKeys.t()} | standard_api_error() | transport_error()
  @callback claim_keys(session, claim :: map()) ::
              {:ok, ClaimKeys.t()} | standard_api_error() | transport_error()

  @callback upload_signing_keys(session, signing_keys_body) ::
              :ok | uia_error() | standard_api_error() | transport_error()
  @callback upload_signatures(session, signatures_body) ::
              {:ok, signature_failures} | standard_api_error() | transport_error()

  @callback list_devices(session) ::
              {:ok, [device_info]} | standard_api_error() | transport_error()
  @callback delete_devices(session, %{required(String.t()) => term()}) ::
              :ok | uia_error() | standard_api_error() | transport_error()

  @callback user_directory_search(session, payload :: map()) ::
              {:ok, map()} | standard_api_error() | transport_error()

  @callback sync(session, sync_query) ::
              {:ok, Sync.t()} | standard_api_error() | transport_error()

  @type profile :: %{
          optional(String.t()) => term()
        }

  @callback get_profile(session, user_id) ::
              {:ok, profile()} | standard_api_error() | transport_error()
  @callback set_display_name(session, String.t()) ::
              :ok | standard_api_error() | transport_error()
  @callback set_avatar_url(session, String.t()) ::
              :ok | standard_api_error() | transport_error()
end
