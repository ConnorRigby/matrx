defmodule Matrx.Olm.Account do
  @moduledoc """
  Wrapper around a Vodozemac account
  """

  # alias Matrx.{
  #   User,
  #   Device
  # }

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          # user_id: String.t(),
          # user: Ecto.Association.NotLoaded.t() | User.t(),
          # device_id: String.t(),
          # device: Ecto.Association.NotLoaded.t() | Device.t(),
          account: Vodozemac.account(),
          pickle: String.t(),
          pickle_data: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @derive {Inspect, [except: [:pickle, :pickle_data]]}
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "account" do
    field(:account, :map, virtual: true)
    field(:pickle, :binary)
    field(:pickle_data, :map, source: :pickle)

    # belongs_to :device, Matrx.Device,
    #   foreign_key: :device_id,
    #   type: :string,
    #   references: :device_id

    # belongs_to :user, Matrx.User,
    #   foreign_key: :user_id,
    #   type: :string,
    #   references: :user_id

    timestamps()
  end

  def changeset(account, attrs \\ %{}) do
    account
    |> cast(attrs, [])

    # |> cast(attrs, [:device_id, :user_id])
    # |> validate_required([:device_id, :user_id])
  end
end
