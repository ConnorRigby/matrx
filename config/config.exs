import Config

config :matrx, ecto_repos: [Matrx.Repo]
test_client = System.get_env("TEST_CLIENT")

database =
  if test_client do
    "test_client_#{test_client}.db"
  else
    "test_client.db"
  end

config :matrx, Matrx.Repo,
  database: database,
  pool_size: 1

if Mix.env() == :test do
  config :matrx, Matrx.Repo,
    database: "test.db",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 1,
    # a single SQLite connection is shared by every test, so let them queue
    queue_target: 5_000,
    queue_interval: 10_000,
    log: false
end

import_config("local.exs")
