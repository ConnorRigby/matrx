defmodule Matrx.Repo.Migrations.CreateMegolmMessageIndexes do
  use Ecto.Migration

  def change do
    # Which event each (session, message index) was first used for, to detect replays
    create table(:megolm_message_indexes, primary_key: false) do
      add :session_id, :string, null: false, primary_key: true
      add :message_index, :integer, null: false, primary_key: true
      add :event_id, :string
      add :origin_server_ts, :integer
      timestamps(updated_at: false)
    end
  end
end
