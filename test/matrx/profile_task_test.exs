defmodule Matrx.ProfileTaskTest do
  use Matrx.RepoCase, async: false

  alias Matrx.{Client, Session}
  alias Matrx.Support.FakeAPI
  alias Mix.Tasks.Matrx.Profile

  setup do
    config = Application.fetch_env(:matrx, Client)
    password = System.get_env("MATRIX_PASSWORD")
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    System.delete_env("MATRIX_PASSWORD")

    on_exit(fn ->
      Mix.shell(shell)

      case config do
        {:ok, value} -> Application.put_env(:matrx, Client, value)
        :error -> Application.delete_env(:matrx, Client)
      end

      if password,
        do: System.put_env("MATRIX_PASSWORD", password),
        else: System.delete_env("MATRIX_PASSWORD")
    end)

    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, _feed} = FakeAPI.start_feed(host: host)
    uri = "http://#{host}"

    Application.put_env(:matrx, Client,
      homeserver: uri,
      username: "bot",
      password: "pw",
      api: FakeAPI
    )

    {:ok, uri: uri}
  end

  test "updates and reads the profile, reusing the stored login" do
    Profile.run(["--display-name", "Friendly Bot", "--avatar-url", "mxc://example/avatar"])
    session = Repo.one!(Session)
    user = session.user_id
    assert_receive {:put_profile, ^user, "displayname", "Friendly Bot"}
    assert_receive {:put_profile, ^user, "avatar_url", "mxc://example/avatar"}

    assert {:ok, %{"displayname" => "Friendly Bot", "avatar_url" => "mxc://example/avatar"}} =
             FakeAPI.get_profile(session, user)

    Profile.run([])
    assert Repo.one!(Session).id == session.id
    refute_receive {:put_profile, _, _, _}, 0
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "Friendly Bot"
  end

  @tag :tmp_dir
  test "uploads an avatar file without encrypting it", %{tmp_dir: dir} do
    path = Path.join(dir, "avatar.png")
    File.write!(path, <<137, 80, 78, 71>>)
    Profile.run(["--avatar", path])
    assert_receive {:upload_media, <<137, 80, 78, 71>>, "image/png", "avatar.png"}
    assert_receive {:put_profile, _, "avatar_url", "mxc://" <> _}
    refute_receive {:put_profile, _, "displayname", _}, 0
  end

  @tag :tmp_dir
  test "supports overriding the image MIME type", %{tmp_dir: dir} do
    path = Path.join(dir, "avatar.bin")
    File.write!(path, "image")
    Profile.run(["--avatar", path, "--content-type", "image/jpeg"])
    assert_receive {:upload_media, "image", "image/jpeg", "avatar.bin"}
  end

  test "empty fields explicitly clear profile values" do
    Profile.run(["--display-name", "", "--avatar-url", ""])
    assert_receive {:put_profile, _, "displayname", ""}
    assert_receive {:put_profile, _, "avatar_url", ""}
  end

  test "invalid options and missing files fail before creating a session" do
    for args <- [
          ["--avatar", "a.png", "--avatar-url", "mxc://example/a"],
          ["--avatar-url", "https://example/a"],
          ["--content-type", "image/png"],
          ["--avatar", "a.wav"],
          ["--avatar", "/nonexistent/avatar.png"],
          ["--unknown"]
        ] do
      assert_raise Mix.Error, fn -> Profile.run(args) end
    end

    assert Repo.aggregate(Session, :count) == 0
  end

  test "CLI credentials override config", ctx do
    System.put_env("MATRIX_PASSWORD", "pw")
    Profile.run(["--homeserver", ctx.uri, "--username", "other", "--display-name", "Other"])
    assert Repo.one!(Session).user_id =~ "@other:"
  end

  test "missing password and settings fail clearly" do
    Application.put_env(
      :matrx,
      Client,
      Keyword.delete(Application.get_env(:matrx, Client), :password)
    )

    assert_raise Mix.Error, ~r/Password required/, fn -> Profile.run([]) end
    Application.delete_env(:matrx, Client)
    assert_raise Mix.Error, ~r/Missing homeserver/, fn -> Profile.run([]) end
  end

  test "help works without credentials" do
    Application.delete_env(:matrx, Client)
    Profile.run(["--help"])
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "--avatar"
  end
end
