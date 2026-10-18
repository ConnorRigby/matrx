defmodule Matrx.SyncLongPollTest do
  use ExUnit.Case, async: true

  alias Matrx.Room
  alias Matrx.RoomSupervisor
  alias Matrx.Support.FakeAPI
  alias Matrx.SyncLongPoll

  @alice "@alice:example.org"
  @bob "@bob:example.org"

  setup do
    {:ok, feed} = FakeAPI.start_feed()
    {:ok, _} = start_supervised({SyncLongPoll, [session: %{feed: feed}, api: FakeAPI]})
    {:ok, feed: feed, room_id: "!#{System.unique_integer([:positive])}:example.org"}
  end

  test "creates rooms from joined timeline state", %{feed: feed, room_id: room_id} do
    FakeAPI.push_sync(
      feed,
      sync(%{
        room_id => %{
          "timeline" => %{
            "events" => [
              state_event("m.room.create", "", %{"creator" => @alice, "room_version" => "11"}),
              state_event("m.room.member", @alice, %{"membership" => "join"})
            ]
          }
        }
      })
    )

    room_pid = await_room(room_id)
    assert {:ok, %{room_version: "11"}} = Room.fetch_state(room_pid, "m.room.create", "")
    assert {:ok, %{membership: :join}} = Room.fetch_state(room_pid, "m.room.member", @alice)
  end

  test "reduces `state` section of a joined room", %{feed: feed, room_id: room_id} do
    FakeAPI.push_sync(
      feed,
      sync(%{
        room_id => %{
          "state" => %{
            "events" => [
              state_event("m.room.encryption", "", %{
                "algorithm" => "m.megolm.v1.aes-sha2"
              }),
              state_event("m.room.member", @bob, %{"membership" => "join"})
            ]
          },
          "timeline" => %{"events" => [], "limited" => true}
        }
      })
    )

    room_pid = await_room(room_id)

    assert {:ok, _encryption} =
             eventually(fn -> Room.fetch_state(room_pid, "m.room.encryption", "") end)

    assert {:ok, %{membership: :join}} = Room.fetch_state(room_pid, "m.room.member", @bob)
  end

  test "later syncs update existing state", %{feed: feed, room_id: room_id} do
    join = fn membership ->
      sync(%{
        room_id => %{
          "timeline" => %{
            "events" => [state_event("m.room.member", @bob, %{"membership" => membership})]
          }
        }
      })
    end

    FakeAPI.push_sync(feed, join.("join"))
    room_pid = await_room(room_id)

    assert {:ok, %{membership: :join}} =
             eventually(fn -> Room.fetch_state(room_pid, "m.room.member", @bob) end)

    FakeAPI.push_sync(feed, join.("leave"))

    assert :leave =
             eventually(fn ->
               case Room.fetch_state(room_pid, "m.room.member", @bob) do
                 {:ok, %{membership: :leave}} -> :leave
                 _ -> nil
               end
             end)
  end

  test "broadcasts non-state timeline events to subscribers", %{feed: feed, room_id: room_id} do
    :ok = Room.subscribe(room_id)

    FakeAPI.push_sync(
      feed,
      sync(%{
        room_id => %{
          "timeline" => %{
            "events" => [
              %{
                "type" => "m.room.message",
                "event_id" => "$1",
                "sender" => @alice,
                "origin_server_ts" => 1,
                "content" => %{"msgtype" => "m.text", "body" => "hi"}
              }
            ]
          }
        }
      })
    )

    assert_receive %{type: "m.room.message", sender: @alice, content: %{body: "hi"}}
  end

  defp sync(joined_rooms) do
    %{
      "next_batch" => "s#{System.unique_integer([:positive])}",
      "rooms" => %{"join" => joined_rooms}
    }
  end

  defp state_event(type, state_key, content) do
    %{
      "type" => type,
      "state_key" => state_key,
      "event_id" => "$#{System.unique_integer([:positive])}",
      "sender" => @alice,
      "origin_server_ts" => System.unique_integer([:positive, :monotonic]),
      "content" => content
    }
  end

  defp await_room(room_id), do: eventually(fn -> RoomSupervisor.whereis(room_id) end)

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      result when result not in [nil, :error] -> result
      _ when attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      other -> flunk("condition not met, last result: #{inspect(other)}")
    end
  end
end
