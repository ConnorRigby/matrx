defmodule Matrx.APIBehaviour do
  @type session :: Matrx.Session.t()

  @type login_ok() :: %{
          access_token: String.t(),
          device_id: String.t(),
          home_server: String.t(),
          user_id: String.t()
        }
  @type standard_api_error :: {:error, Matrx.APIError.t()}
  @type register_payload() :: %{
          required(:username) => String.t(),
          required(:password) => String.t(),
          optional(:device_id) => String.t(),
          optional(:device_display_name) => String.t()
        }
  @type transaction_id :: String.t()
  @type message :: %{msgtype: :"m.text", body: String.t()}

  @type room_id :: String.t()
  @type user_id() :: String.t()

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
  @type room() :: %{id: room_id()}
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

  @doc """
  Resets and saves an access token to the device

  ```elixir
  iex> {:ok, session} = Matrx.API.login_password(%Matrx.Session{home_server_uri: URI.parse("http://localhost:8008")}, %{type: "m.id.user", user: username}, password)
  {:ok, %{device_id: "EGHMKVZZCA",
     home_server: "matrix.pressy4pie.dev",
     user_id: "@username:matrix.pressy4pie.dev"
  }}
  ```
  """
  @callback login_password(session, username :: String.t(), password :: String.t()) ::
              {:ok, login_ok} | standard_api_error()
  @callback register(session, register_payload) :: {:ok, login_ok()} | standard_api_error()

  @callback create_room(session, create_room_payload) :: {:ok, room()} | standard_api_error()
  @callback join_room(session, room_id) :: :ok | standard_api_error()
  @callback leave_room(session, room_id) :: :ok | standard_api_error()
  @callback kick_room(session, room_id, kick_room_payload) :: :ok | standard_api_error()
  # @callback send_room_message(session, room_id, transaction_id, message) ::
  #             {:ok, %{event_id: String.t()}} | standard_api_error()
end
