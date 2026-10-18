defmodule Matrx.SessionTest do
  use Matrx.RepoCase, async: true
  alias Matrx.{Olm, Session}

  @login %{access_token: "tok", device_id: "DEV1", user_id: "@alice:example.org"}

  test "create and get round trips with a usable account" do
    {:ok, account} = Olm.create_account()
    keys = Olm.identity_keys(account)

    assert {:ok, %Session{home_server_uri: %URI{host: "example.org"}}} =
             Session.create("http://example.org:8008", account, @login)

    assert {:ok, session} = Session.get("@alice:example.org", "DEV1")
    assert session.access_token == "tok"
    assert session.home_server_uri == URI.parse("http://example.org:8008")
    assert Olm.identity_keys(session.account) == keys
  end

  test "saved account keeps generated keys across reloads" do
    {:ok, account} = Olm.create_account()
    {:ok, _} = Session.create("http://example.org", account, @login)
    Olm.generate_one_time_keys(account, 5)
    {:ok, _} = Olm.save_account(account)
    {:ok, session} = Session.get(@login.user_id, @login.device_id)
    assert map_size(Vodozemac.one_time_keys(session.account.account)) == 5
  end

  test "device is unique per homeserver and user" do
    {:ok, a1} = Olm.create_account()
    {:ok, a2} = Olm.create_account()
    assert {:ok, _} = Session.create("http://example.org", a1, @login)
    assert {:error, changeset} = Session.create("http://example.org", a2, @login)
    assert %{home_server_uri: [_]} = errors_on(changeset)
  end

  test "access token is not inspected" do
    {:ok, account} = Olm.create_account()
    {:ok, session} = Session.create("http://example.org", account, @login)
    refute inspect(session) =~ "tok\""
  end

  test "delete removes session and account" do
    {:ok, account} = Olm.create_account()
    {:ok, session} = Session.create("http://example.org", account, @login)
    assert :ok = Session.delete(session)
    assert :error = Session.get(@login.user_id, @login.device_id)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end)
  end
end
