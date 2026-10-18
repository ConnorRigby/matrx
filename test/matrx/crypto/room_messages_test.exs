defmodule Matrx.Crypto.RoomMessagesTest do
  use Matrx.RepoCase, async: true

  alias Matrx.API.Event
  alias Matrx.API.Event.RoomMessage
  alias Matrx.Crypto.{Devices, OlmMessages, RoomMessages, ToDevice}
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

    for {me, other} <- [{alice, bob}, {bob, alice}] do
      Devices.track(me, [other.user_id])
      :ok = Devices.refresh(me, @opts)
    end

    {:ok, outbound} = Megolm.create_outbound_session()
    {:ok, alice: alice, bob: bob, outbound: outbound}
  end

  # Gives bob the room key, as a real m.room_key to-device event would
  defp share_key(ctx, room_id \\ @room_id) do
    [bobs_device] = Devices.list(ctx.alice, ctx.bob.user_id)

    content = %{
      "algorithm" => RoomMessages.algorithm(),
      "room_id" => room_id,
      "session_id" => ctx.outbound.session_id,
      "session_key" => ctx.outbound.session_key
    }

    {:ok, messages, []} =
      OlmMessages.encrypt(ctx.alice, [{bobs_device, "m.room_key", content}], @opts)

    event =
      Event.from_response(%{
        "type" => "m.room.encrypted",
        "sender" => ctx.alice.user_id,
        "content" => messages[ctx.bob.user_id][ctx.bob.device_id]
      })

    :ok = ToDevice.handle(ctx.bob, event, @opts)
  end

  defp payload(type, content, room_id \\ @room_id),
    do: Jason.encode!(%{"type" => type, "content" => content, "room_id" => room_id})

  defp text(body), do: payload("m.room.message", %{"msgtype" => "m.text", "body" => body})

  defp encrypted(ctx, plaintext, overrides \\ %{}) do
    {:ok, _outbound, ciphertext} = Megolm.encrypt(ctx.outbound, plaintext)
    envelope(ctx, ciphertext, overrides)
  end

  defp envelope(ctx, ciphertext, overrides) do
    Event.from_response(
      Map.merge(
        %{
          "type" => "m.room.encrypted",
          "event_id" => "$event#{System.unique_integer([:positive])}",
          "sender" => ctx.alice.user_id,
          "origin_server_ts" => 1_700_000_000_000,
          "unsigned" => %{"age" => 5},
          "content" => %{
            "algorithm" => RoomMessages.algorithm(),
            "sender_key" => Olm.identity_keys(ctx.alice.account).curve25519,
            "device_id" => ctx.alice.device_id,
            "session_id" => ctx.outbound.session_id,
            "ciphertext" => ciphertext
          }
        },
        overrides
      )
    )
  end

  test "decrypts a message and keeps the envelope's metadata", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("hello bob"))

    assert {:ok, decrypted} = RoomMessages.decrypt(ctx.bob, @room_id, event)
    assert decrypted.type == "m.room.message"
    assert %RoomMessage{body: "hello bob", msgtype: "m.text"} = decrypted.content
    assert decrypted.event_id == event.event_id
    assert decrypted.sender == ctx.alice.user_id
    assert decrypted.origin_server_ts == event.origin_server_ts
    assert decrypted.unsigned == %{age: 5}
    assert decrypted.state_key == nil
  end

  test "decrypts messages in any order", ctx do
    share_key(ctx)
    events = for i <- 1..3, do: encrypted(ctx, text("message #{i}"))

    for {event, i} <- Enum.reverse(Enum.with_index(events, 1)) do
      assert {:ok, %{content: %{body: body}}} = RoomMessages.decrypt(ctx.bob, @room_id, event)
      assert body == "message #{i}"
    end
  end

  test "decrypting the same event again succeeds", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("again"))

    assert {:ok, _} = RoomMessages.decrypt(ctx.bob, @room_id, event)
    assert {:ok, _} = RoomMessages.decrypt(ctx.bob, @room_id, event)
  end

  test "a message index can't be reused by another event", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("original"))
    assert {:ok, _} = RoomMessages.decrypt(ctx.bob, @room_id, event)

    replay = %{event | event_id: "$replay"}
    assert {:error, :replayed} = RoomMessages.decrypt(ctx.bob, @room_id, replay)
  end

  test "reports an unknown session until the key arrives", ctx do
    event = encrypted(ctx, text("early"))
    assert {:error, :unknown_session} = RoomMessages.decrypt(ctx.bob, @room_id, event)

    share_key(ctx)
    assert {:ok, %{content: %{body: "early"}}} = RoomMessages.decrypt(ctx.bob, @room_id, event)
  end

  test "keys are scoped to the session that received them", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("not for alice"))
    assert {:error, :unknown_session} = RoomMessages.decrypt(ctx.alice, @room_id, event)
  end

  test "rejects an event delivered in another room than the key's", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("moved"))
    assert {:error, :room_mismatch} = RoomMessages.decrypt(ctx.bob, "!other:example.org", event)
  end

  test "rejects a payload that names another room", ctx do
    share_key(ctx)
    event = encrypted(ctx, payload("m.room.message", %{"body" => "x"}, "!other:example.org"))
    assert {:error, :room_mismatch} = RoomMessages.decrypt(ctx.bob, @room_id, event)
  end

  test "rejects an event whose sender doesn't own the key's device", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("spoofed"), %{"sender" => ctx.bob.user_id})
    assert {:error, :unknown_device} = RoomMessages.decrypt(ctx.bob, @room_id, event)
  end

  test "rejects an event claiming another sender key", ctx do
    share_key(ctx)
    event = encrypted(ctx, text("x"))
    forged = %{event | content: %{event.content | sender_key: "AAAA"}}
    assert {:error, :sender_key_mismatch} = RoomMessages.decrypt(ctx.bob, @room_id, forged)
  end

  test "rejects ciphertext that can't be decrypted", ctx do
    share_key(ctx)

    for ciphertext <- ["not base64!", "AwgAEhA", 42] do
      event = envelope(ctx, ciphertext, %{})
      assert {:error, {:decrypt_failed, _}} = RoomMessages.decrypt(ctx.bob, @room_id, event)
    end
  end

  test "rejects ciphertext made by a different session", ctx do
    share_key(ctx)
    {:ok, other} = Megolm.create_outbound_session()
    {:ok, _, ciphertext} = Megolm.encrypt(other, text("forged"))
    event = envelope(ctx, ciphertext, %{})
    assert {:error, {:decrypt_failed, _}} = RoomMessages.decrypt(ctx.bob, @room_id, event)
  end

  test "rejects payloads that aren't a typed event", ctx do
    share_key(ctx)

    for plaintext <- ["not json", "[]", ~s({"type": "m.room.message"}), payload(1, %{})] do
      event = encrypted(ctx, plaintext)
      assert {:error, :invalid_payload} = RoomMessages.decrypt(ctx.bob, @room_id, event)
    end
  end

  test "only handles megolm room events", ctx do
    event = %{encrypted(ctx, text("x")) | type: "m.room.message"}
    assert {:error, :unsupported_event} = RoomMessages.decrypt(ctx.bob, @room_id, event)

    event =
      encrypted(ctx, text("x"), %{"content" => %{"algorithm" => "m.olm.v1.curve25519-aes-sha2"}})

    refute RoomMessages.encrypted?(event)
  end
end
