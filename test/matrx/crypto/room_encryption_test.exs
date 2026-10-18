defmodule Matrx.Crypto.RoomEncryptionTest do
  use Matrx.RepoCase, async: true

  alias Matrx.API.Event
  alias Matrx.Crypto.{Device, Devices, RoomEncryption, RoomMessages, ToDevice}
  alias Matrx.Megolm.{InboundSession, OutboundSession, Share}
  alias Matrx.Support.FakeAPI
  alias Matrx.{Olm, Session}

  @room_id "!room:example.org"

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, alice} = Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)

    ctx = %{feed: feed, uri: uri, alice: alice, bob: bob}
    refresh(alice, [alice, bob])
    refresh(bob, [alice, bob])
    {:ok, ctx}
  end

  defp refresh(session, users) do
    Devices.track(session, Enum.map(users, & &1.user_id))
    Devices.mark_outdated(session, Enum.map(users, & &1.user_id))
    :ok = Devices.refresh(session, api: FakeAPI)
  end

  defp room(sessions, overrides \\ %{}) do
    Map.merge(
      %{
        encryption: %Event.RoomEncryption{algorithm: RoomMessages.algorithm()},
        members: Enum.map(sessions, & &1.user_id)
      },
      overrides
    )
  end

  defp send_text(session, room, body) do
    {:ok, %{event_id: event_id}} =
      RoomEncryption.send_event(
        session,
        @room_id,
        "m.room.message",
        %{"msgtype" => "m.text", "body" => body},
        api: FakeAPI,
        room: room
      )

    assert_receive {:send_room_message, @room_id, "m.room.encrypted", content}
    event(session, event_id, content)
  end

  defp event(sender, event_id, content) do
    Event.from_response(%{
      "type" => "m.room.encrypted",
      "event_id" => event_id,
      "sender" => sender.user_id,
      "origin_server_ts" => 1,
      "content" => content
    })
  end

  # Delivers the room key that was just sent to `recipient`, like its sync would
  defp deliver_key(sender, recipient) do
    assert_receive {:send_to_device, messages}
    content = messages[recipient.user_id][recipient.device_id]
    assert content, "no key was sent to #{recipient.user_id} #{recipient.device_id}"

    event =
      Event.from_response(%{
        "type" => "m.room.encrypted",
        "sender" => sender.user_id,
        "content" => content
      })

    assert :ok = ToDevice.handle(recipient, event, api: FakeAPI)
    messages
  end

  defp outbound_sessions, do: Repo.all(OutboundSession)

  test "shares the room key, then sends a message the member can read", ctx do
    event = send_text(ctx.alice, room([ctx.alice, ctx.bob]), "hello bob")
    # the key is sent before the message, and never to the sending device
    messages = deliver_key(ctx.alice, ctx.bob)
    refute Map.has_key?(messages, ctx.alice.user_id)

    assert {:ok, decrypted} = RoomMessages.decrypt(ctx.bob, @room_id, event)
    assert decrypted.type == "m.room.message"
    assert decrypted.content.body == "hello bob"
    assert event.content.device_id == ctx.alice.device_id
    assert event.content.sender_key == Olm.identity_keys(ctx.alice.account).curve25519
  end

  test "the sender can read the echo of its own message", ctx do
    event = send_text(ctx.alice, room([ctx.alice, ctx.bob]), "note to self")

    assert {:ok, %{content: %{body: "note to self"}}} =
             RoomMessages.decrypt(ctx.alice, @room_id, event)
  end

  test "the key is shared once per device", ctx do
    room = room([ctx.alice, ctx.bob])
    first = send_text(ctx.alice, room, "one")
    second = send_text(ctx.alice, room, "two")

    assert first.content.session_id == second.content.session_id
    assert_received {:send_to_device, _}
    refute_received {:send_to_device, _}
    assert Repo.aggregate(Share, :count) == 1
  end

  test "sends to each of the member's other devices", ctx do
    {:ok, bob2} = Session.login_password(ctx.uri, %{user: "bob"}, "pw", api: FakeAPI)
    {:ok, alice2} = Session.login_password(ctx.uri, %{user: "alice"}, "pw", api: FakeAPI)
    refresh(ctx.alice, [ctx.alice, ctx.bob])
    refresh(bob2, [ctx.alice, ctx.bob])
    refresh(alice2, [ctx.alice, ctx.bob])

    event = send_text(ctx.alice, room([ctx.alice, ctx.bob]), "everyone")

    assert_receive {:send_to_device, messages}

    assert Map.keys(messages[ctx.bob.user_id]) |> Enum.sort() ==
             Enum.sort([ctx.bob.device_id, bob2.device_id])

    assert Map.keys(messages[ctx.alice.user_id]) == [alice2.device_id]

    for recipient <- [ctx.bob, bob2] do
      content = messages[recipient.user_id][recipient.device_id]
      key_event = %Event{type: "m.room.encrypted", sender: ctx.alice.user_id, content: nil}

      key_event = %{
        key_event
        | content: Event.content_from_response("m.room.encrypted", content)
      }

      assert :ok = ToDevice.handle(recipient, key_event, api: FakeAPI)

      assert {:ok, %{content: %{body: "everyone"}}} =
               RoomMessages.decrypt(recipient, @room_id, event)
    end
  end

  test "a device that appears later only gets the key it is missing", ctx do
    room = room([ctx.alice, ctx.bob])
    send_text(ctx.alice, room, "before")
    deliver_key(ctx.alice, ctx.bob)

    {:ok, bob2} = Session.login_password(ctx.uri, %{user: "bob"}, "pw", api: FakeAPI)
    refresh(ctx.alice, [ctx.bob])
    refresh(bob2, [ctx.alice, ctx.bob])

    after_event = send_text(ctx.alice, room, "after")
    messages = deliver_key(ctx.alice, bob2)
    assert Map.keys(messages[ctx.bob.user_id]) == [bob2.device_id]

    assert {:ok, %{content: %{body: "after"}}} = RoomMessages.decrypt(bob2, @room_id, after_event)
  end

  test "a device added later can't read earlier messages", ctx do
    room = room([ctx.alice, ctx.bob])
    before_event = send_text(ctx.alice, room, "before")
    deliver_key(ctx.alice, ctx.bob)

    {:ok, bob2} = Session.login_password(ctx.uri, %{user: "bob"}, "pw", api: FakeAPI)
    refresh(ctx.alice, [ctx.bob])
    refresh(bob2, [ctx.alice, ctx.bob])
    send_text(ctx.alice, room, "after")
    deliver_key(ctx.alice, bob2)

    assert {:error, {:decrypt_failed, _}} = RoomMessages.decrypt(bob2, @room_id, before_event)
    assert {:ok, _} = RoomMessages.decrypt(ctx.bob, @room_id, before_event)
  end

  test "rotates after the configured number of messages", ctx do
    room =
      room([ctx.alice, ctx.bob], %{
        encryption: %Event.RoomEncryption{
          algorithm: RoomMessages.algorithm(),
          rotation_period_msgs: 2
        }
      })

    ids = for i <- 1..3, do: send_text(ctx.alice, room, "m#{i}").content.session_id
    assert [a, a, b] = ids
    assert a != b
    # the new session's key is sent too
    assert_received {:send_to_device, _}
    assert_received {:send_to_device, _}
    assert [%{session_id: ^b}] = outbound_sessions()
  end

  test "rotates when the session is too old", ctx do
    room =
      room([ctx.alice, ctx.bob], %{
        encryption: %Event.RoomEncryption{
          algorithm: RoomMessages.algorithm(),
          rotation_period_ms: 1
        }
      })

    first = send_text(ctx.alice, room, "old")
    Process.sleep(5)
    second = send_text(ctx.alice, room, "new")
    assert first.content.session_id != second.content.session_id
  end

  test "rotates when a member leaves, so they can't read what comes next", ctx do
    first = send_text(ctx.alice, room([ctx.alice, ctx.bob]), "both")
    deliver_key(ctx.alice, ctx.bob)

    second = send_text(ctx.alice, room([ctx.alice]), "only me")
    assert first.content.session_id != second.content.session_id

    # bob never got the new key
    refute_received {:send_to_device, _}
    assert {:error, :unknown_session} = RoomMessages.decrypt(ctx.bob, @room_id, second)
  end

  test "rotates when a device is removed", ctx do
    {:ok, bob2} = Session.login_password(ctx.uri, %{user: "bob"}, "pw", api: FakeAPI)
    refresh(ctx.alice, [ctx.bob])
    room = room([ctx.alice, ctx.bob])

    first = send_text(ctx.alice, room, "two devices")
    FakeAPI.delete_device(ctx.feed, ctx.bob.user_id, bob2.device_id)
    refresh(ctx.alice, [ctx.bob])
    second = send_text(ctx.alice, room, "one device")

    assert first.content.session_id != second.content.session_id
  end

  test "devices we couldn't reach are retried on the next send", ctx do
    [bobs_device] = Devices.list(ctx.alice, ctx.bob.user_id)
    ghost = %{bobs_device | device_id: "GHOST", curve25519: String.duplicate("B", 43)}
    Repo.insert!(Ecto.put_meta(ghost, state: :built))
    room = room([ctx.alice, ctx.bob])

    first = send_text(ctx.alice, room, "ghost can't read")
    assert_receive {:send_to_device, messages}
    assert Map.keys(messages[ctx.bob.user_id]) == [ctx.bob.device_id]
    assert Repo.aggregate(Share, :count) == 1

    send_text(ctx.alice, room, "still no key")
    # bob already has it; only the ghost is attempted, and fails again
    refute_received {:send_to_device, _}
    assert first.content.session_id
  end

  test "nothing is sent when no device could be reached", ctx do
    Repo.delete_all(Device)
    send_text(ctx.alice, room([ctx.alice, ctx.bob]), "alone")
    refute_received {:send_to_device, _}
  end

  test "stores an inbound session for our own messages", ctx do
    send_text(ctx.alice, room([ctx.alice, ctx.bob]), "mine")
    [outbound] = outbound_sessions()

    inbound =
      Repo.get_by!(InboundSession, session_id: outbound.session_id, owner_id: ctx.alice.id)

    assert inbound.owner_id == ctx.alice.id
    assert inbound.room_id == @room_id
  end

  test "rejects rooms that aren't encrypted or use another algorithm", ctx do
    assert {:error, :room_not_encrypted} =
             RoomEncryption.send_event(ctx.alice, "!unknown:example.org", "m.room.message", %{},
               api: FakeAPI
             )

    room = room([ctx.alice], %{encryption: %Event.RoomEncryption{algorithm: "m.other"}})

    assert {:error, :unsupported_algorithm} =
             RoomEncryption.send_event(ctx.alice, @room_id, "m.room.message", %{},
               api: FakeAPI,
               room: room
             )

    assert outbound_sessions() == []
  end
end
