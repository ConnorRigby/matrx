defmodule Matrx.Repo.Migrations.CreateMegolmSessionsTables do
  use Ecto.Migration

  def change do
    create table(:megolm_inbound_sessions, primary_key: false) do
      add :session_id, :string, null: false, primary_key: true
      add :session_key, :string, null: false
      # add :room_id, :string, null: false
      # add :user_id, references(:users, column: :user_id, type: :string), null: false
      # add :message_index, :integer
      add :pickle, :json, null: false
      timestamps()
    end

    create unique_index(:megolm_inbound_sessions, [:session_id])
    create unique_index(:megolm_inbound_sessions, [:session_key])
    # create index(:megolm_inbound_sessions, [:room_id])

    create table(:megolm_outbound_sessions, primary_key: false) do
      add :session_id, :string, null: false, primary_key: true
      add :session_key, :string, null: false
      # add :room_id, :string, null: false
      # add :user_id, references(:users, column: :user_id, type: :string), null: false
      # add :message_index, :integer
      add :pickle, :json, null: false
      timestamps()
    end

    create unique_index(:megolm_outbound_sessions, [:session_id])
    create unique_index(:megolm_outbound_sessions, [:session_key])
    # create index(:megolm_outbound_sessions, [:room_id])
  end
end
