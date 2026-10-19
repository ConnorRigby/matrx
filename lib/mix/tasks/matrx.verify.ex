defmodule Mix.Tasks.Matrx.Verify do
  use Mix.Task

  @shortdoc "Bootstrap cross-signing and sign the bot's device"
  @moduledoc """
  Log in to an already registered bot account, create its cross-signing identity,
  and sign this device.

      mix matrx.verify --homeserver https://matrix.example.com --username mybot

  Reads the password from `MATRIX_PASSWORD`, falling back to `:password` in
  `config :matrx, Matrx.Client`. The homeserver and username also default to
  that config. Passwords are not accepted on the command line.

  Starts Matrx and runs its database migrations, but does not start the host
  application or a sync loop. Run in the same Mix environment and with the same
  database configuration as the bot. Stored credentials, Olm keys, and
  cross-signing keys are reused on subsequent runs.

  This bootstraps a fresh cross-signing identity; it does not perform interactive
  SAS verification with another client or import an existing identity. Existing
  server identities are never reset. Keep the database safe: it holds the
  credentials and private keys needed to reuse this device.

  Options:

    * `--homeserver`: homeserver URL
    * `--username`: localpart of the registered bot user
    * `--help`: show this help
  """

  alias Matrx.Crypto.{CrossSigning, Devices}
  alias Matrx.{Client, Repo, Session}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [homeserver: :string, username: :string, help: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("Invalid arguments. See mix help matrx.verify.")
    end

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      Mix.Task.run("app.config")
      config = Keyword.merge(Application.get_env(:matrx, Client, []), opts)
      validate!(config)
      {:ok, _} = Application.ensure_all_started(:matrx)
      :ok = Repo.migrate()
      verify!(config)
    end
  end

  defp validate!(config) do
    for key <- [:homeserver, :username] do
      unless is_binary(config[key]) and config[key] != "" do
        Mix.raise("Missing #{key}. Set --#{key} or config :matrx, Matrx.Client.")
      end
    end

    uri = URI.parse(config[:homeserver])

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      Mix.raise("The homeserver must be an http:// or https:// URL.")
    end
  end

  defp verify!(config) do
    password = System.get_env("MATRIX_PASSWORD") || config[:password]
    opts = [api: Keyword.get(config, :api, Matrx.API), password: password]

    with {:ok, session} <-
           Session.restore_or_login(config[:homeserver], config[:username], password, opts),
         :ok <- sign(session, opts),
         true <- Devices.trusted?(session, session.user_id, session.device_id) do
      Mix.shell().info(
        "Cross-signing verified for #{session.user_id}, device #{session.device_id}."
      )
    else
      {:error, :password_required} ->
        Mix.raise(
          "Password required. Set MATRIX_PASSWORD or config :matrx, Matrx.Client, password: ..."
        )

      {:error, :cross_signing_exists} ->
        Mix.raise(
          "This account already has a cross-signing identity not held in this database. " <>
            "No keys were replaced. Use the original database; importing an identity " <>
            "or SAS verification is not supported yet."
        )

      {:error, reason} ->
        Mix.raise("Could not verify the device: #{inspect(reason)}")

      false ->
        Mix.raise("The homeserver did not report a valid cross-signature for this device.")
    end
  end

  defp sign(session, opts) do
    if CrossSigning.bootstrapped?(session),
      do: CrossSigning.sign_device(session, session.device_id, opts),
      else: CrossSigning.bootstrap(session, opts)
  end
end
