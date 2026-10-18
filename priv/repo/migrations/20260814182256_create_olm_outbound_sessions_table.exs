defmodule Matrx.Repo.Migrations.CreateOlmOutboundSessionsTable do
  use Ecto.Migration

  def change do
    create table(:olm_outbound_sessions, primary_key: false) do
      add :session_id, :string, null: false, primary_key: true
      add :pickle, :json, null: false
      timestamps()
    end

    create unique_index(:olm_outbound_sessions, [:session_id])
  end
end
