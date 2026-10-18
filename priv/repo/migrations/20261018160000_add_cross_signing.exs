defmodule Matrx.Repo.Migrations.AddCrossSigning do
  use Ecto.Migration

  def change do
    # Our own cross-signing keys, as 32 byte ed25519 seeds
    create table(:cross_signing_keys, primary_key: false) do
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :usage, :string, null: false, primary_key: true
      add :public, :string, null: false
      add :seed, :binary, null: false
      timestamps()
    end

    # Whether the device is signed by our own cross-signing keys
    alter table(:devices) do
      add :trusted, :boolean, null: false, default: false
    end
  end
end
