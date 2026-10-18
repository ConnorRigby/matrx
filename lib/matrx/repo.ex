defmodule Matrx.Repo do
  use Ecto.Repo, otp_app: :matrx, adapter: Ecto.Adapters.SQLite3

  @doc "Run the migrations that have not run yet"
  @spec migrate() :: :ok
  def migrate do
    path = Application.app_dir(:matrx, "priv/repo/migrations")
    Ecto.Migrator.run(__MODULE__, path, :up, all: true, log: false)
    :ok
  end
end
