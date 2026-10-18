defmodule Matrx.Session do
  @moduledoc """
  A logged in device: homeserver, credentials and the Olm account that
  belongs to this `{user_id, device_id}`.

  The struct is what gets passed to `Matrx.API` and `Matrx.SyncLongPoll`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]
  alias Matrx.{Olm, Repo}
  alias Matrx.Olm.Account

  defmodule URIType do
    @moduledoc false
    use Ecto.Type

    def type, do: :string
    def cast(%URI{} = uri), do: {:ok, uri}
    def cast(uri) when is_binary(uri), do: {:ok, URI.parse(uri)}
    def cast(_), do: :error
    def load(uri) when is_binary(uri), do: {:ok, URI.parse(uri)}
    def dump(%URI{} = uri), do: {:ok, URI.to_string(uri)}
    def dump(_), do: :error
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          home_server_uri: URI.t(),
          user_id: String.t(),
          device_id: String.t(),
          access_token: String.t(),
          account_id: Ecto.UUID.t(),
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @derive {Inspect, except: [:access_token]}
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "sessions" do
    field(:home_server_uri, URIType)
    field(:user_id, :string)
    field(:device_id, :string)
    field(:access_token, :string)
    belongs_to(:account, Account, type: :binary_id)
    timestamps()
  end

  @required [:home_server_uri, :user_id, :device_id, :access_token, :account_id]

  def changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> foreign_key_constraint(:account_id)
    |> unique_constraint(:account_id)
    |> unique_constraint([:home_server_uri, :user_id, :device_id])
  end

  @doc """
  Store a session for an already created Olm account. `login` is the map
  returned by `Matrx.API.register/2` or `Matrx.API.login_password/3`.
  """
  @spec create(URI.t() | String.t(), Account.t(), %{
          access_token: String.t(),
          device_id: String.t(),
          user_id: String.t()
        }) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(home_server_uri, %Account{} = account, login) do
    with {:ok, session} <-
           %__MODULE__{}
           |> changeset(%{
             home_server_uri: home_server_uri,
             user_id: login.user_id,
             device_id: login.device_id,
             access_token: login.access_token,
             account_id: account.id
           })
           |> Repo.insert() do
      {:ok, %{session | account: account}}
    end
  end

  @doc """
  Register a new user, create the Olm account for the new device, and publish
  its device and one-time keys. Pass `api: module` to swap `Matrx.API`.
  """
  @spec register(URI.t() | String.t(), Matrx.APIBehaviour.register_payload(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def register(home_server_uri, payload, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)
    uri = to_uri(home_server_uri)

    with {:ok, login} <- api.register(anonymous(uri), payload) do
      finish_login(uri, login, api)
    end
  end

  @doc """
  Log in with a password. See `register/3` for what else happens.

  The `:device_id` option asks the server to use that device id. Every login
  creates a new Olm account, so only reuse an id of a device you have deleted.
  """
  @spec login_password(URI.t() | String.t(), map(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def login_password(home_server_uri, identifier, password, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)
    uri = to_uri(home_server_uri)

    api_opts = Keyword.take(opts, [:device_id])

    with {:ok, login} <- call_login(api, anonymous(uri), identifier, password, api_opts) do
      finish_login(uri, login, api)
    end
  end

  defp call_login(api, session, identifier, password, []),
    do: api.login_password(session, identifier, password)

  defp call_login(api, session, identifier, password, opts),
    do: api.login_password(session, identifier, password, opts)

  defp finish_login(uri, login, api) do
    with {:ok, account} <- Olm.create_account(),
         {:ok, session} <- create(uri, account, login),
         {:ok, _count} <- Matrx.Crypto.Keys.upload(session, api: api) do
      {:ok, session}
    end
  end

  defp anonymous(uri), do: %{home_server_uri: uri, access_token: nil}
  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: URI.parse(uri)

  @doc "Fetch a stored session with its Olm account unpickled and ready to use"
  @spec get(String.t(), String.t()) :: {:ok, t()} | :error
  def get(user_id, device_id) do
    case Repo.get_by(__MODULE__, user_id: user_id, device_id: device_id) do
      nil -> :error
      session -> {:ok, load_account(session)}
    end
  end

  @spec load_account(t()) :: t()
  def load_account(%__MODULE__{} = session) do
    session = Repo.preload(session, :account)
    %{session | account: Olm.load_account(session.account)}
  end

  @doc "Remove the session (and its account) when logging out"
  @spec delete(t()) :: :ok
  def delete(%__MODULE__{} = session) do
    Repo.delete_all(from(a in Account, where: a.id == ^session.account_id))
    :ok
  end
end
