defmodule Matrx.Megolm.Share do
  @moduledoc "A device an outbound Megolm session's key was sent to"
  use Ecto.Schema

  @primary_key false
  schema "megolm_outbound_shares" do
    field(:session_id, :string, primary_key: true)
    field(:user_id, :string, primary_key: true)
    field(:device_id, :string, primary_key: true)
    timestamps(updated_at: false)
  end
end
