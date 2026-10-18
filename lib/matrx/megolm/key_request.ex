defmodule Matrx.Megolm.KeyRequest do
  @moduledoc "A room key we asked our other devices for"
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "megolm_key_requests" do
    field(:owner_id, :binary_id)
    field(:room_id, :string)
    field(:session_id, :string)
    field(:sender_key, :string)
    timestamps(updated_at: false)
  end
end
