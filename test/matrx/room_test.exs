defmodule Matrx.RoomTest do
  use ExUnit.Case, async: true
  import Matrx.Support.Fixtures

  alias Matrx.Room
  alias Matrx.API.Sync.Rooms.JoinedRoom

  describe "fetch_state/3 and lookup_state/2" do
    test "m.room.create" do
      assert {:ok, pid} = start_supervised({Room, room_id: unique_id()})

      :ok =
        Room.sync_join(
          pid,
          joined_room([
            m_room_create()
          ])
        )

      assert {:ok, content} = Room.fetch_state(pid, "m.room.create", "")
      assert content.room_version == "11"
    end

    test "m.room.member" do
      assert {:ok, pid} = start_supervised({Room, room_id: unique_id()})

      :ok =
        Room.sync_join(
          pid,
          joined_room([
            m_room_create(),
            m_room_member("@alice:example.org", "Alice"),
            m_room_member("@bob:example.org", "Bob")
          ])
        )

      assert {:ok, %{membership: :join, displayname: "Alice"}} =
               Room.fetch_state(pid, "m.room.member", "@alice:example.org")

      assert members = Room.lookup_state(pid, "m.room.member")

      assert {"@alice:example.org",
              %Matrx.API.Event.RoomMember{
                avatar_url: "mxc://example.org/SEsfnsuifSDFSSEF",
                displayname: "Alice",
                membership: :join
              }} in members

      assert {"@bob:example.org",
              %Matrx.API.Event.RoomMember{
                avatar_url: "mxc://example.org/SEsfnsuifSDFSSEF",
                displayname: "Bob",
                membership: :join
              }} in members
    end
  end

  describe "messaging" do
    setup :create_room_with_two_members

    test "m.room.message", %{room: pid, room_id: room_id} do
      Room.subscribe(room_id)

      :ok =
        Room.sync_join(
          pid,
          joined_room([
            m_room_message("hello, world")
          ])
        )

      assert_receive %Matrx.API.Event{
        type: "m.room.message",
        event_id: "$143273582443PhrSn:example.org",
        sender: "@example:example.org",
        state_key: nil,
        origin_server_ts: _,
        content: %Matrx.API.Event.RoomMessage{
          body: "hello, world",
          "m.mentions": nil,
          msgtype: "m.text"
        },
        unsigned: %{:age => 1234, "membership" => "join"}
      }
    end
  end

  defp create_room_with_two_members(_tags) do
    room_id = unique_id()
    assert {:ok, pid} = start_supervised({Room, room_id: room_id})

    :ok =
      Room.sync_join(
        pid,
        joined_room([
          m_room_create(),
          m_room_member("@alice:example.org", "Alice"),
          m_room_member("@bob:example.org", "Bob")
        ])
      )

    {:ok, %{room: pid, room_id: room_id}}
  end

  defp unique_id, do: Ecto.UUID.generate()

  defp joined_room(events) do
    %JoinedRoom{
      timeline: %{events: events, limited: false, prev_batch: nil}
    }
  end

  describe "state updates" do
    test "lookup_state and dump_state only return the latest state of a key" do
      assert {:ok, pid} = start_supervised({Room, room_id: unique_id()})

      member = fn membership ->
        joined_room([
          m_room_create(),
          update_in(m_room_member("@bob:example.org", "Bob").content.membership, fn _ ->
            membership
          end)
        ])
      end

      :ok = Room.sync_join(pid, member.(:join))
      :ok = Room.sync_join(pid, member.(:leave))

      assert [{"@bob:example.org", %{membership: :leave}}] =
               Room.lookup_state(pid, "m.room.member")

      assert [{{"m.room.member", "@bob:example.org"}, %{membership: :leave}}] =
               Enum.filter(Room.dump_state(pid), &match?({{"m.room.member", _}, _}, &1))
    end
  end
end
