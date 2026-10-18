defmodule Matrx.SessionLoginTest do
  use Matrx.RepoCase, async: true

  alias Matrx.Support.FakeAPI
  alias Matrx.Session

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    {:ok, host: host, feed: feed, uri: URI.parse("http://#{host}")}
  end

  test "register stores the session and publishes keys", %{uri: uri, host: host} do
    assert {:ok, session} =
             Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)

    assert session.user_id == "@alice:#{host}"
    assert session.account.account

    assert_receive {:upload_keys, %{"device_keys" => keys, "one_time_keys" => otks}}
    assert keys["user_id"] == session.user_id
    assert keys["device_id"] == session.device_id
    assert map_size(otks) == 50

    assert {:ok, stored} = Session.get(session.user_id, session.device_id)
    assert Vodozemac.one_time_keys(stored.account.account) == %{}
  end

  test "login_password creates a fresh account for the device", %{uri: uri} do
    assert {:ok, session} =
             Session.login_password(uri, %{type: "m.id.user", user: "bob"}, "pw", api: FakeAPI)

    assert_receive {:upload_keys, %{"device_keys" => %{"device_id" => device_id}}}
    assert device_id == session.device_id
  end

  test "login_password can ask for a device id", %{uri: uri} do
    assert {:ok, session} =
             Session.login_password(uri, %{user: "bob"}, "pw",
               api: FakeAPI,
               device_id: "MYDEVICE"
             )

    assert session.device_id == "MYDEVICE"
    assert_receive {:upload_keys, %{"device_keys" => %{"device_id" => "MYDEVICE"}}}
  end

  test "failed registration leaves nothing behind", %{uri: uri} do
    defmodule FailingAPI do
      def register(_, _), do: {:error, :nope}
    end

    assert {:error, :nope} =
             Session.register(uri, %{username: "x", password: "y"}, api: FailingAPI)

    assert Repo.aggregate(Matrx.Olm.Account, :count) == 0
  end
end
