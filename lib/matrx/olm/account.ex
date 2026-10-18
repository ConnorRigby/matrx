defmodule Matrx.Olm.Account do
  @moduledoc """
  Wrapper around a Vodozemac account
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          account: Vodozemac.account(),
          pickle: String.t(),
          pickle_data: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @derive {Inspect, [except: [:pickle, :pickle_data]]}
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "account" do
    field :account, :map, virtual: true
    field :pickle, :binary
    field :pickle_data, :map, source: :pickle
    has_one :session, Matrx.Session, foreign_key: :account_id
    timestamps()
  end

  def changeset(account, attrs \\ %{}) do
    account
    |> cast(attrs, [])
  end
end
