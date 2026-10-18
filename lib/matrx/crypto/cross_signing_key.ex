defmodule Matrx.Crypto.CrossSigningKey do
  @moduledoc "One of our own cross-signing keys, `usage` being master, self_signing or user_signing"
  use Ecto.Schema

  @derive {Inspect, except: [:seed]}
  @primary_key false
  schema "cross_signing_keys" do
    belongs_to :session, Matrx.Session, type: :binary_id, primary_key: true
    field :usage, :string, primary_key: true
    field :public, :string
    field :seed, :binary
    timestamps()
  end
end
