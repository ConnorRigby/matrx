defmodule Matrx.SyncLongPollEncryptionTest do
  # The sync process touches the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false

  alias Matrx.API.Event
  alias Matrx.Crypto.{Devices, OlmMessages, RoomMessages}
  alias Matrx.Support.FakeAPI
  alias Matrx.{Megolm, Olm, Room, Session, SyncLongPoll}

  @opts [api: FakeAPI]

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, alice} = Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)

    for {me, other} <- [{alice, bob}, {bob, alice}] do
      Devices.track(me, [other.user_id])
      :ok = Devices.refresh(me, @opts)
    end

    {:ok, outbound} = Megolm.create_outbound_session()
    room_id = "!#{System.unique_integer([:positive])}:#{host}"
    Room.subscribe(room_id)

    # drain the key upload notification sent by registration
    flush()
    start_supervised!({SyncLongPoll, [session: bob, api: FakeAPI]})

    {:ok, feed: feed, alice: alice, bob: bob, outbound: outbound, room_id: room_id}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp room_key_event(ctx) do
    [bobs_device] = Devices.list(ctx.alice, ctx.bob.user_id)

    content = %{
      "algorithm" => RoomMessages.algorithm(),
      "room_id" => ctx.room_id,
      "session_id" => ctx.outbound.session_id,
      "session_key" => ctx.outbound.session_key
    }

    {:ok, messages, []} =
      OlmMessages.encrypt(ctx.alice, [{bobs_device, "m.room_key", content}], @opts)

    %{
      "type" => "m.room.encrypted",
      "sender" => ctx.alice.user_id,
      "content" => messages[ctx.bob.user_id][ctx.bob.device_id]
    }
  end

  defp message_event(ctx, body) do
    plaintext =
      %{
        "type" => "m.room.message",
        "content" => %{"msgtype" => "m.text", "body" => body},
        "room_id" => ctx.room_id
      }
      |> :json.encode()
      |> IO.iodata_to_binary()

    {:ok, _, ciphertext} = Megolm.encrypt(ctx.outbound, plaintext)

    %{
      "type" => "m.room.encrypted",
      "event_id" => "$#{System.unique_integer([:positive])}",
      "sender" => ctx.alice.user_id,
      "origin_server_ts" => 1_700_000_000_000,
      "content" => %{
        "algorithm" => RoomMessages.algorithm(),
        "sender_key" => Olm.identity_keys(ctx.alice.account).curve25519,
        "device_id" => ctx.alice.device_id,
        "session_id" => ctx.outbound.session_id,
        "ciphertext" => ciphertext
      }
    }
  end

  defp push(feed, extra) do
    FakeAPI.push_sync(
      feed,
      Map.put(extra, "next_batch", "s#{System.unique_integer([:positive])}")
    )
  end

  defp rooms(room_id, events),
    do: %{"rooms" => %{"join" => %{room_id => %{"timeline" => %{"events" => events}}}}}

  defp to_device(events), do: %{"to_device" => %{"events" => events}}

  test "broadcasts decrypted messages when the key came first", ctx do
    push(ctx.feed, to_device([room_key_event(ctx)]))
    push(ctx.feed, rooms(ctx.room_id, [message_event(ctx, "hello")]))

    assert_receive %Event{type: "m.room.message", content: %{body: "hello"}}, 2000
    refute_receive %Event{type: "m.room.encrypted"}, 100
  end

  test "decrypts a message in the same sync as its key", ctx do
    body =
      Map.merge(
        rooms(ctx.room_id, [message_event(ctx, "together")]),
        to_device([room_key_event(ctx)])
      )

    push(ctx.feed, body)

    assert_receive %Event{type: "m.room.message", content: %{body: "together"}}, 2000
  end

  test "holds a message until its key arrives", ctx do
    push(ctx.feed, rooms(ctx.room_id, [message_event(ctx, "late key")]))

    # the undecryptable event is still delivered as it was received
    assert_receive %Event{type: "m.room.encrypted"}, 2000
    refute_receive %Event{type: "m.room.message"}, 100

    push(ctx.feed, to_device([room_key_event(ctx)]))
    assert_receive %Event{type: "m.room.message", content: %{body: "late key"}}, 2000
  end

  test "a replayed message is not decrypted twice", ctx do
    push(ctx.feed, to_device([room_key_event(ctx)]))
    original = message_event(ctx, "once")
    push(ctx.feed, rooms(ctx.room_id, [original]))
    assert_receive %Event{type: "m.room.message", content: %{body: "once"}}, 2000

    push(ctx.feed, rooms(ctx.room_id, [%{original | "event_id" => "$replayed"}]))
    assert_receive %Event{type: "m.room.encrypted", event_id: "$replayed"}, 2000
    refute_receive %Event{type: "m.room.message"}, 100
  end
end
