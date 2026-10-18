defmodule Matrx.Repo.Migrations.CreateMegolmKeyRequests do
  use Ecto.Migration

  def change do
    # Room keys we asked our other devices for. Only keys we asked for are accepted back.
    create table(:megolm_key_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false

      add :room_id, :string, null: false
      add :session_id, :string, null: false
      add :sender_key, :string, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:megolm_key_requests, [:owner_id, :session_id])
  end
end
