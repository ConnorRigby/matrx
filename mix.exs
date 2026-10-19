defmodule Matrx.MixProject do
  use Mix.Project

  def project do
    [
      app: :matrx,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix]],
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Matrx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jcs, "~> 0.2.0"},
      {:req, "~> 0.6.1"},
      {:mime, "~> 2.0"},
      {:rustler, "~> 0.38.0"},
      {:x509, "~> 0.9.2"},
      {:ed25519, "~> 1.5"},
      {:ecto_sqlite3, "~> 0.17"},
      {:phoenix_pubsub, "~> 2.2"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [test: ["ecto.migrate --quiet", "test"]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
