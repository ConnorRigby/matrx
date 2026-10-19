defmodule Matrx.VerifyTaskTest do
  use Matrx.RepoCase, async: false

  alias Matrx.Crypto.{CrossSigning, Devices}
  alias Matrx.Support.FakeAPI
  alias Matrx.{Client, Session}
  alias Mix.Tasks.Matrx.Verify

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
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = "http://#{host}"

    Application.put_env(:matrx, Client,
      homeserver: uri,
      username: "bot",
      password: "pw",
      api: FakeAPI
    )

    {:ok, feed: feed, uri: uri}
  end

  test "bootstraps a fresh account and reuses its device on subsequent runs", ctx do
    FakeAPI.require_uia(ctx.feed, "pw")
    Verify.run([])
    session = Repo.one!(Session) |> Session.load_account()
    assert CrossSigning.bootstrapped?(session)
    assert Devices.trusted?(session, session.user_id, session.device_id)
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ session.device_id
    refute message =~ "token_"

    Verify.run([])
    assert Repo.one!(Session).id == session.id
    assert Repo.aggregate(Matrx.Crypto.CrossSigningKey, :count) == 3
    assert_receive {:mix_shell, :info, [_]}
  end

  test "CLI options override config and the environment supplies the password", ctx do
    System.put_env("MATRIX_PASSWORD", "secret")
    FakeAPI.require_uia(ctx.feed, "secret")
    Verify.run(["--homeserver", ctx.uri, "--username", "other"])
    assert Repo.one!(Session).user_id =~ "@other:"
  end

  test "refuses to replace an identity made elsewhere", ctx do
    {:ok, original} =
      Session.login_password(ctx.uri, %{user: "bot"}, "pw", api: FakeAPI)

    assert :ok = CrossSigning.bootstrap(original, api: FakeAPI)

    {:ok, fresh} =
      Session.login_password(ctx.uri, %{user: "bot"}, "pw", api: FakeAPI)

    # Select the unverified device deterministically, without deleting the
    # original device or its cross-signing identity from the fake homeserver.
    Repo.delete!(original)

    assert_raise Mix.Error, ~r/already has a cross-signing identity/, fn -> Verify.run([]) end
    refute CrossSigning.bootstrapped?(fresh)
  end

  test "missing password fails explicitly before creating a session" do
    Application.put_env(
      :matrx,
      Client,
      Application.get_env(:matrx, Client) |> Keyword.delete(:password)
    )

    assert_raise Mix.Error, ~r/Password required/, fn -> Verify.run([]) end
    assert Repo.aggregate(Session, :count) == 0
  end

  test "invalid arguments and missing settings fail clearly" do
    assert_raise Mix.Error, ~r/Invalid arguments/, fn -> Verify.run(["--reset"]) end
    Application.put_env(:matrx, Client, [])
    assert_raise Mix.Error, ~r/Missing homeserver/, fn -> Verify.run([]) end

    assert_raise Mix.Error, ~r/http/, fn ->
      Verify.run(["--homeserver", "not-a-url", "--username", "bot"])
    end
  end

  test "help does not require credentials" do
    Application.delete_env(:matrx, Client)
    Verify.run(["--help"])
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "SAS"
  end
end
