defmodule Matrx.Repo.Migrations.CreateOlmOutboundSessionsTable do
  use Ecto.Migration

  def change do
    create table(:olm_outbound_sessions, primary_key: false) do
      add :session_id, :string, null: false, primary_key: true
      # add :device_id, references(:devices, column: :device_id, type: :string), null: false
      # add :user_id, references(:users, column: :user_id, type: :string), null: false
      # add :sender_key, :string, null: false
      # add :recipient_key, :string, null: false
      add :pickle, :json, null: false
      timestamps()
    end
    create unique_index(:olm_outbound_sessions, [:session_id])
    # create index(:olm_sessions, [:sender_key])
    # create index(:olm_sessions, [:recipient_key])
  end
end
