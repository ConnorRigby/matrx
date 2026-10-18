defmodule Matrx.Crypto.TrackedUser do
  @moduledoc "A user whose device list we keep up to date"

  use Ecto.Schema

  @primary_key false
  schema "tracked_users" do
    belongs_to :session, Matrx.Session, type: :binary_id, primary_key: true
    field :user_id, :string, primary_key: true
    field :outdated, :boolean, default: true
    timestamps()
  end
end
