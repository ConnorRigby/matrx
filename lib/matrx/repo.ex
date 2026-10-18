defmodule Matrx.Repo do
  use Ecto.Repo, otp_app: :matrx, adapter: Ecto.Adapters.SQLite3
end
