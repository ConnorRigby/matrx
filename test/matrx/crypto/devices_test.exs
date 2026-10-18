defmodule Matrx.Crypto.DevicesTest do
  use Matrx.RepoCase, async: true

  alias Matrx.Crypto.{Devices, Keys}
  alias Matrx.Support.FakeAPI
  alias Matrx.{Olm, Session}

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, me} = Session.register(uri, %{username: "me", password: "pw"}, api: FakeAPI)
    {:ok, host: host, feed: feed, uri: uri, me: me, bob: "@bob:#{host}"}
  end

  # A real, self signed device for `user` as it would be reported by the server
  defp device(uri, user, device_id) do
    {:ok, account} = Olm.create_account()
    login = %{access_token: "t", device_id: device_id, user_id: user}
    {:ok, session} = Session.create(uri, account, login)
    {session, Keys.device_keys(session)}
  end

  defp refresh(me), do: Devices.refresh(me, api: FakeAPI)

  test "stores verified devices of tracked users", ctx do
    {bob_phone, keys} = device(ctx.uri, ctx.bob, "PHONE")
    FakeAPI.put_device(ctx.feed, ctx.bob, "PHONE", keys)

    :ok = Devices.track(ctx.me, [ctx.bob])
    assert Devices.outdated_users(ctx.me) == [ctx.bob]
    assert :ok = refresh(ctx.me)
    assert Devices.outdated_users(ctx.me) == []

    ids = Olm.identity_keys(bob_phone.account)
    assert [%{device_id: "PHONE"} = d] = Devices.list(ctx.me, ctx.bob)
    assert d.curve25519 == ids.curve25519
    assert d.ed25519 == ids.ed25519
    assert Devices.get_by_curve25519(ctx.me, ids.curve25519).device_id == "PHONE"
  end

  test "rejects devices with a bad signature or mismatched ids", ctx do
    {_, keys} = device(ctx.uri, ctx.bob, "TAMPERED")
    tampered = put_in(keys, ["keys", "curve25519:TAMPERED"], "AAAA")
    {_, other} = device(ctx.uri, "@mallory:#{ctx.host}", "SPOOF")
    FakeAPI.put_device(ctx.feed, ctx.bob, "TAMPERED", tampered)
    FakeAPI.put_device(ctx.feed, ctx.bob, "SPOOF", other)

    Devices.track(ctx.me, [ctx.bob])
    assert :ok = refresh(ctx.me)
    assert Devices.list(ctx.me, ctx.bob) == []
  end

  test "ignores `unsigned` when verifying", ctx do
    {_, keys} = device(ctx.uri, ctx.bob, "PHONE")
    keys = Map.put(keys, "unsigned", %{"device_display_name" => "Bob's phone"})
    FakeAPI.put_device(ctx.feed, ctx.bob, "PHONE", keys)

    Devices.track(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    assert [%{display_name: "Bob's phone"}] = Devices.list(ctx.me, ctx.bob)
  end

  test "removes devices the server no longer reports", ctx do
    {_, a} = device(ctx.uri, ctx.bob, "A")
    {_, b} = device(ctx.uri, ctx.bob, "B")
    FakeAPI.put_device(ctx.feed, ctx.bob, "A", a)
    FakeAPI.put_device(ctx.feed, ctx.bob, "B", b)
    Devices.track(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    assert [_, _] = Devices.list(ctx.me, ctx.bob)

    FakeAPI.delete_device(ctx.feed, ctx.bob, "B")
    Devices.mark_outdated(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    assert [%{device_id: "A"}] = Devices.list(ctx.me, ctx.bob)
  end

  test "refuses a changed signing key for a known device id", ctx do
    {_, original} = device(ctx.uri, ctx.bob, "PHONE")
    FakeAPI.put_device(ctx.feed, ctx.bob, "PHONE", original)
    Devices.track(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    %{ed25519: ed} = Devices.get(ctx.me, ctx.bob, "PHONE")

    {_, impostor} = device(URI.parse("http://impostor.example"), ctx.bob, "PHONE")
    FakeAPI.put_device(ctx.feed, ctx.bob, "PHONE", impostor)
    Devices.mark_outdated(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    assert %{ed25519: ^ed} = Devices.get(ctx.me, ctx.bob, "PHONE")
  end

  test "users on failing servers stay outdated", ctx do
    FakeAPI.set_failures(ctx.feed, %{ctx.host => %{}})
    Devices.track(ctx.me, [ctx.bob])
    assert :ok = refresh(ctx.me)
    assert Devices.outdated_users(ctx.me) == [ctx.bob]
  end

  test "mark_outdated ignores untracked users and untrack forgets devices", ctx do
    Devices.mark_outdated(ctx.me, [ctx.bob])
    refute Devices.tracked?(ctx.me, ctx.bob)

    {_, keys} = device(ctx.uri, ctx.bob, "PHONE")
    FakeAPI.put_device(ctx.feed, ctx.bob, "PHONE", keys)
    Devices.track(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    :ok = Devices.untrack(ctx.me, [ctx.bob])
    refute Devices.tracked?(ctx.me, ctx.bob)
    assert Devices.list(ctx.me, ctx.bob) == []
  end

  test "track keeps an up to date user up to date", ctx do
    Devices.track(ctx.me, [ctx.bob])
    :ok = refresh(ctx.me)
    Devices.track(ctx.me, [ctx.bob])
    assert Devices.outdated_users(ctx.me) == []
  end
end
