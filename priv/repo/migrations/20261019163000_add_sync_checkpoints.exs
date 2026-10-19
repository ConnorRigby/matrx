defmodule Matrx.Repo.Migrations.AddSyncCheckpoints do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :sync_token, :string
    end

    create table(:sync_deliveries, primary_key: false) do
      add :owner_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :room_id, :string, primary_key: true
      add :event_id, :string, primary_key: true
      add :phase, :string, primary_key: true
    end
  end
end
