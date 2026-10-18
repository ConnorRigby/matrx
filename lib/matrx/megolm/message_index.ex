defmodule Matrx.Megolm.MessageIndex do
  @moduledoc "Records the event a Megolm message index was first seen in, to detect replays"
  use Ecto.Schema

  @primary_key false
  schema "megolm_message_indexes" do
    field(:session_id, :string, primary_key: true)
    field(:message_index, :integer, primary_key: true)
    field(:event_id, :string)
    field(:origin_server_ts, :integer)
    timestamps(updated_at: false)
  end
end
