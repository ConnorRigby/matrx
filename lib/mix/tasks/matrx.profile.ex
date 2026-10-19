defmodule Mix.Tasks.Matrx.Profile do
  use Mix.Task

  @shortdoc "View or update the bot's Matrix profile"
  @moduledoc """
  View or update the logged-in bot user's profile.

      mix matrx.profile
      mix matrx.profile --display-name "My Bot" --avatar ./avatar.png
      mix matrx.profile --avatar-url mxc://matrix.example.com/media-id
      mix matrx.profile --display-name "" --avatar-url ""

  Options:

    * `--display-name`: set the display name; an empty string clears it
    * `--avatar`: upload an image from the filesystem and use it as the avatar
    * `--avatar-url`: use an existing mxc:// URL; an empty string clears it
    * `--content-type`: override the avatar file's inferred image MIME type
    * `--homeserver`, `--username`: override `config :matrx, Matrx.Client`
    * `--help`: show this help

  Passwords come from MATRIX_PASSWORD or client config, never CLI arguments.
  Uses the same stored login and database as the bot. Starts Matrx and migrates
  its database, but does not start the host application or a sync loop.

  Profile avatars are public media, not encrypted attachments. Only fields
  explicitly supplied are changed. Updates are separate server requests, not
  atomic: a later failure does not undo an earlier successful change or upload.
  Standard Matrix profiles support display names and avatars; no nonstandard
  biography or status fields are set.
  """

  alias Matrx.{Client, Repo, Session}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          homeserver: :string,
          username: :string,
          display_name: :string,
          avatar: :string,
          avatar_url: :string,
          content_type: :string,
          help: :boolean
        ]
      )

    if rest != [] or invalid != [],
      do: Mix.raise("Invalid arguments. See mix help matrx.profile.")

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      validate_options!(opts)
      # Read the file before logging in or changing any server state.
      avatar = read_avatar!(opts)
      Mix.Task.run("app.config")
      config = Keyword.merge(Application.get_env(:matrx, Client, []), opts)
      validate_login!(config)
      {:ok, _} = Application.ensure_all_started(:matrx)
      :ok = Repo.migrate()
      api = Keyword.get(config, :api, Matrx.API)
      password = System.get_env("MATRIX_PASSWORD") || config[:password]

      session =
        case Session.restore_or_login(config[:homeserver], config[:username], password, api: api) do
          {:ok, session} ->
            session

          {:error, :password_required} ->
            Mix.raise("Password required. Set MATRIX_PASSWORD or the client password config.")

          {:error, reason} ->
            Mix.raise("Could not log in: #{inspect(reason)}")
        end

      update!(session, api, opts, avatar)

      case api.get_profile(session, session.user_id) do
        {:ok, profile} ->
          Mix.shell().info("Profile for #{session.user_id}:\n" <> inspect(profile, pretty: true))

        {:error, reason} ->
          Mix.raise("Could not fetch profile: #{inspect(reason)}")
      end
    end
  end

  defp validate_options!(opts) do
    if Keyword.has_key?(opts, :avatar) and Keyword.has_key?(opts, :avatar_url),
      do: Mix.raise("Use only one of --avatar and --avatar-url.")

    if Keyword.has_key?(opts, :content_type) and not Keyword.has_key?(opts, :avatar),
      do: Mix.raise("--content-type requires --avatar.")

    if Keyword.has_key?(opts, :avatar_url) do
      uri = URI.parse(opts[:avatar_url])

      unless opts[:avatar_url] == "" or
               (uri.scheme == "mxc" and is_binary(uri.host) and uri.host != "" and
                  is_binary(uri.path) and uri.path not in ["", "/"] and
                  is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo)) do
        Mix.raise("--avatar-url must be an mxc:// URI, or an empty string to clear it.")
      end
    end
  end

  defp read_avatar!(opts) do
    if path = opts[:avatar] do
      type = opts[:content_type] || MIME.from_path(path)

      unless String.starts_with?(type, "image/"),
        do: Mix.raise("Avatar must have an image MIME type.")

      case File.read(path) do
        {:ok, data} -> {data, type, Path.basename(path)}
        {:error, reason} -> Mix.raise("Could not read avatar: #{:file.format_error(reason)}")
      end
    end
  end

  defp validate_login!(config) do
    for key <- [:homeserver, :username] do
      unless is_binary(config[key]) and config[key] != "",
        do: Mix.raise("Missing #{key}. Set --#{key} or config :matrx, Matrx.Client.")
    end

    uri = URI.parse(config[:homeserver])

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
      do: Mix.raise("The homeserver must be an http:// or https:// URL.")
  end

  defp update!(session, api, opts, avatar) do
    if avatar do
      {data, type, filename} = avatar

      case api.upload_media(session, data, type, filename) do
        {:ok, %{content_uri: uri}} ->
          check!(api.set_avatar_url(session, uri), "set avatar")

        {:error, reason} ->
          Mix.raise("Could not upload avatar: #{inspect(reason)}")
      end
    end

    if Keyword.has_key?(opts, :avatar_url),
      do: check!(api.set_avatar_url(session, opts[:avatar_url]), "set avatar")

    if Keyword.has_key?(opts, :display_name),
      do: check!(api.set_display_name(session, opts[:display_name]), "set display name")
  end

  defp check!(:ok, _action), do: :ok
  defp check!({:error, reason}, action), do: Mix.raise("Could not #{action}: #{inspect(reason)}")
end
