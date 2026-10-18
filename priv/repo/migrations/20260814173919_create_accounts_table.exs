defmodule Matrx.Repo.Migrations.CreateAccountsTable do
  use Ecto.Migration

  def change do
    create table(:account, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :pickle, :json, null: false
      timestamps()
    end
  end
end
