defmodule Matrx.Crypto.ToDeviceTest do
  use Matrx.RepoCase, async: true

  alias Matrx.API.Event
  alias Matrx.Crypto.{Devices, OlmMessages, ToDevice}
  alias Matrx.Megolm.InboundSession
  alias Matrx.Support.FakeAPI
  alias Matrx.{Megolm, Olm, Session}

  @opts [api: FakeAPI]
  @room_id "!room:example.org"

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, _feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, alice} = Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)

    Devices.track(alice, [bob.user_id])
    :ok = Devices.refresh(alice, @opts)
    [bobs_device] = Devices.list(alice, bob.user_id)

    {:ok, outbound} = Megolm.create_outbound_session()

    {:ok, alice: alice, bob: bob, bobs_device: bobs_device, outbound: outbound}
  end

  defp room_key(outbound, overrides \\ %{}) do
    Map.merge(
      %{
        "algorithm" => "m.megolm.v1.aes-sha2",
        "room_id" => @room_id,
        "session_id" => outbound.session_id,
        "session_key" => outbound.session_key
      },
      overrides
    )
  end

  # The to-device event bob would receive for `content` sent by alice
  defp to_device_event(ctx, type, content) do
    {:ok, messages, []} =
      OlmMessages.encrypt(ctx.alice, [{ctx.bobs_device, type, content}], @opts)

    Event.from_response(%{
      "type" => "m.room.encrypted",
      "sender" => ctx.alice.user_id,
      "content" => messages[ctx.bob.user_id][ctx.bob.device_id]
    })
  end

  test "stores a received room key with its ownership", ctx do
    event = to_device_event(ctx, "m.room_key", room_key(ctx.outbound))

    assert :ok = ToDevice.handle(ctx.bob, event, @opts)

    assert %InboundSession{} =
             stored = Repo.get_by(InboundSession, session_id: ctx.outbound.session_id)

    assert stored.owner_id == ctx.bob.id
    assert stored.room_id == @room_id
    assert stored.sender_key == Olm.identity_keys(ctx.alice.account).curve25519
  end

  test "the stored key decrypts messages from the sender", ctx do
    :ok =
      ToDevice.handle(ctx.bob, to_device_event(ctx, "m.room_key", room_key(ctx.outbound)), @opts)

    {:ok, _outbound, ciphertext} = Megolm.encrypt(ctx.outbound, "hello bob")
    inbound = Repo.get_by(InboundSession, session_id: ctx.outbound.session_id)
    inbound = Megolm.load_inbound(inbound)

    assert {:ok, _, "hello bob"} = Megolm.decrypt(inbound, ciphertext)
  end

  test "a resent key does not replace the stored one", ctx do
    :ok =
      ToDevice.handle(ctx.bob, to_device_event(ctx, "m.room_key", room_key(ctx.outbound)), @opts)

    before = Repo.get_by(InboundSession, session_id: ctx.outbound.session_id)

    resend = room_key(ctx.outbound, %{"room_id" => "!other:example.org"})
    assert :ok = ToDevice.handle(ctx.bob, to_device_event(ctx, "m.room_key", resend), @opts)

    assert Repo.get_by(InboundSession, session_id: ctx.outbound.session_id).room_id ==
             before.room_id

    assert Repo.aggregate(InboundSession, :count) == 1
  end

  test "rejects a malformed session key", ctx do
    bad = room_key(ctx.outbound, %{"session_key" => "bm90IGEga2V5"})

    assert {:error, :invalid_session_key} =
             ToDevice.handle(ctx.bob, to_device_event(ctx, "m.room_key", bad), @opts)

    assert Repo.aggregate(InboundSession, :count) == 0
  end

  test "rejects a session key that belongs to another session id", ctx do
    {:ok, other} = Megolm.create_outbound_session()
    bad = room_key(ctx.outbound, %{"session_key" => other.session_key})

    assert {:error, :invalid_session_key} =
             ToDevice.handle(ctx.bob, to_device_event(ctx, "m.room_key", bad), @opts)
  end

  test "rejects keys with a missing field or unknown algorithm", ctx do
    for overrides <- [%{"room_id" => nil}, %{"algorithm" => "m.megolm.v2"}] do
      assert {:error, :invalid_room_key} =
               ToDevice.handle(
                 ctx.bob,
                 to_device_event(ctx, "m.room_key", room_key(ctx.outbound, overrides)),
                 @opts
               )
    end
  end

  test "ignores other encrypted device events", ctx do
    event = to_device_event(ctx, "m.dummy", %{})
    assert :ok = ToDevice.handle(ctx.bob, event, @opts)
    assert Repo.aggregate(InboundSession, :count) == 0
  end

  test "ignores unencrypted device events", ctx do
    assert :ok = ToDevice.handle(ctx.bob, %Event{type: "m.room_key", sender: "@x:y"}, @opts)
  end
end
