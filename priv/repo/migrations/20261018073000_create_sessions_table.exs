defmodule Matrx.Repo.Migrations.CreateSessionsTable do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :home_server_uri, :string, null: false
      add :user_id, :string, null: false
      add :device_id, :string, null: false
      add :access_token, :string, null: false
      add :account_id, references(:account, type: :binary_id, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:sessions, [:home_server_uri, :user_id, :device_id])
    create unique_index(:sessions, [:account_id])
  end
end
