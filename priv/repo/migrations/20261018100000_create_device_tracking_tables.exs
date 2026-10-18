defmodule Matrx.Repo.Migrations.CreateDeviceTrackingTables do
  use Ecto.Migration

  def change do
    create table(:tracked_users, primary_key: false) do
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :user_id, :string, null: false, primary_key: true
      # true until we have fetched the user's devices with /keys/query
      add :outdated, :boolean, null: false, default: true
      timestamps()
    end

    create table(:devices, primary_key: false) do
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :user_id, :string, null: false, primary_key: true
      add :device_id, :string, null: false, primary_key: true
      add :curve25519, :string, null: false
      add :ed25519, :string, null: false
      add :algorithms, {:array, :string}, null: false, default: []
      add :display_name, :string
      timestamps()
    end

    create index(:devices, [:session_id, :curve25519])
  end
end
