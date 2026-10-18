defmodule Matrx.RoomSendTest do
  # The room and sync processes use the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false

  alias Matrx.API.Event
  alias Matrx.Crypto.{Devices, RoomMessages}
  alias Matrx.Megolm.OutboundSession
  alias Matrx.Support.FakeAPI
  alias Matrx.{Room, Session, SyncLongPoll}

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, alice} = Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)
    room_id = "!#{System.unique_integer([:positive])}:#{host}"
    Room.subscribe(room_id)
    {:ok, feed: feed, alice: alice, bob: bob, room_id: room_id}
  end

  defp push(feed, extra),
    do:
      FakeAPI.push_sync(
        feed,
        Map.put(extra, "next_batch", "s#{System.unique_integer([:positive])}")
      )

  defp state_event(type, state_key, content) do
    %{
      "type" => type,
      "state_key" => state_key,
      "sender" => "@x:y",
      "event_id" => "$s#{System.unique_integer([:positive])}",
      "origin_server_ts" => 1,
      "content" => content
    }
  end

  defp join_room(feed, room_id, users, encrypted?) do
    encryption =
      if encrypted?,
        do: [state_event("m.room.encryption", "", %{"algorithm" => RoomMessages.algorithm()})],
        else: []

    members = for u <- users, do: state_event("m.room.member", u, %{"membership" => "join"})

    push(feed, %{
      "rooms" => %{
        "join" => %{
          room_id => %{
            "state" => %{"events" => encryption ++ members},
            "timeline" => %{"events" => []}
          }
        }
      }
    })
  end

  defp wait_for_room(room_id, fun) do
    Enum.find_value(1..100, fn _ ->
      result = Room.encryption_info(room_id)

      if fun.(result) do
        true
      else
        Process.sleep(20)
        nil
      end
    end) || flunk("room state never arrived")
  end

  test "unknown rooms can't be sent to", ctx do
    assert {:error, :unknown_room} =
             Room.send_event("!nope:example.org", ctx.alice, "m.room.message", %{}, api: FakeAPI)
  end

  test "sends plaintext to rooms that aren't encrypted", ctx do
    start_supervised!({SyncLongPoll, [session: ctx.bob, api: FakeAPI]})
    join_room(ctx.feed, ctx.room_id, [ctx.alice.user_id, ctx.bob.user_id], false)
    wait_for_room(ctx.room_id, fn _ -> Matrx.RoomSupervisor.whereis(ctx.room_id) != nil end)
    content = %{"msgtype" => "m.text", "body" => "hi"}

    assert {:ok, %{event_id: _}} =
             Room.send_event(ctx.room_id, ctx.alice, "m.room.message", content, api: FakeAPI)

    assert_receive {:send_room_message, _, "m.room.message", ^content}
    refute_received {:send_to_device, _}
  end

  test "alice's message reaches bob's sync, decrypted", ctx do
    start_supervised!({SyncLongPoll, [session: ctx.bob, api: FakeAPI]})
    join_room(ctx.feed, ctx.room_id, [ctx.alice.user_id, ctx.bob.user_id], true)
    wait_for_room(ctx.room_id, &match?({:ok, _}, &1))
    # bob's sync already knows alice's devices because they share an encrypted room
    wait_for_devices(ctx.bob, ctx.alice.user_id)

    content = %{"msgtype" => "m.text", "body" => "hello bob"}

    assert {:ok, %{event_id: event_id}} =
             Room.send_event(ctx.room_id, ctx.alice, "m.room.message", content, api: FakeAPI)

    assert_receive {:send_to_device, messages}
    assert_receive {:send_room_message, _, "m.room.encrypted", encrypted}
    refute encrypted["ciphertext"] =~ "hello bob"

    push(ctx.feed, %{
      "to_device" => %{
        "events" => [
          %{
            "type" => "m.room.encrypted",
            "sender" => ctx.alice.user_id,
            "content" => messages[ctx.bob.user_id][ctx.bob.device_id]
          }
        ]
      }
    })

    push(ctx.feed, %{
      "rooms" => %{
        "join" => %{
          ctx.room_id => %{
            "timeline" => %{
              "events" => [
                %{
                  "type" => "m.room.encrypted",
                  "event_id" => event_id,
                  "sender" => ctx.alice.user_id,
                  "origin_server_ts" => 5,
                  "content" => encrypted
                }
              ]
            }
          }
        }
      }
    })

    assert_receive %Event{
                     type: "m.room.message",
                     event_id: ^event_id,
                     content: %{body: "hello bob"}
                   },
                   2000
  end

  test "concurrent sends share a single megolm session", ctx do
    start_supervised!({SyncLongPoll, [session: ctx.bob, api: FakeAPI]})
    join_room(ctx.feed, ctx.room_id, [ctx.alice.user_id, ctx.bob.user_id], true)
    wait_for_room(ctx.room_id, &match?({:ok, _}, &1))

    results =
      1..8
      |> Task.async_stream(
        fn i ->
          Room.send_event(ctx.room_id, ctx.alice, "m.room.message", %{"body" => "#{i}"},
            api: FakeAPI
          )
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert [%OutboundSession{message_count: 8}] = Repo.all(OutboundSession)
  end

  defp wait_for_devices(session, user_id) do
    Enum.find_value(1..100, fn _ ->
      if Devices.list(session, user_id) != [] do
        true
      else
        Process.sleep(20)
        nil
      end
    end) || flunk("devices never arrived")
  end
end
