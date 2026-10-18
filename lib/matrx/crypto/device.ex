defmodule Matrx.Crypto.Device do
  @moduledoc """
  Another user's (or our own) device whose keys we have verified.
  * `trusted` means our own cross-signing keys signed it.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t(),
          user_id: String.t(),
          device_id: String.t(),
          curve25519: String.t(),
          ed25519: String.t(),
          algorithms: [String.t()],
          display_name: String.t() | nil,
          trusted: boolean()
        }

  @primary_key false
  schema "devices" do
    belongs_to :session, Matrx.Session, type: :binary_id, primary_key: true
    field :user_id, :string, primary_key: true
    field :device_id, :string, primary_key: true
    field :curve25519, :string
    field :ed25519, :string
    field :algorithms, {:array, :string}, default: []
    field :display_name, :string
    field :trusted, :boolean, default: false
    timestamps()
  end
end
