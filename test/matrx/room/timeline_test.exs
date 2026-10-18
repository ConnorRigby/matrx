defmodule Matrx.Room.TimelineTest do
  use ExUnit.Case, async: true
  alias Matrx.Room.Timeline
  import Matrx.Support.Fixtures

  test "fetch_state/2" do
    timeline = Timeline.init("room1")
    timeline = Timeline.reduce_state(timeline, [m_room_create()])
    assert {:ok, content} = Timeline.fetch_state(timeline, "m.room.create", "")
    assert content.room_version == "11"
  end

  test "room membership" do
    timeline = Timeline.init("room1")

    timeline =
      Timeline.reduce_state(timeline, [
        m_room_create(),
        m_room_member("@alice:example.org", "Alice"),
        m_room_member("@bob:example.org", "Bob")
      ])

    assert {:ok, %{membership: :join, displayname: "Alice"}} =
             Timeline.fetch_state(timeline, "m.room.member", "@alice:example.org")

    assert members = Timeline.lookup_state(timeline, "m.room.member")

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

  test "get all events" do
    timeline =
      "room1"
      |> Timeline.init()
      |> Timeline.reduce_state([
        m_room_create(),
        m_room_member("@alice:example.org", "Alice"),
        m_room_member("@bob:example.org", "Bob")
      ])

    assert [
             {{"m.room.member", "@alice:example.org"},
              %Matrx.API.Event.RoomMember{
                avatar_url: "mxc://example.org/SEsfnsuifSDFSSEF",
                displayname: "Alice",
                membership: :join
              }},
             {{"m.room.create", ""},
              %Matrx.API.Event.RoomCreate{creator: nil, room_version: "11"}},
             {{"m.room.member", "@bob:example.org"},
              %Matrx.API.Event.RoomMember{
                avatar_url: "mxc://example.org/SEsfnsuifSDFSSEF",
                displayname: "Bob",
                membership: :join
              }}
           ] = Timeline.dump_state(timeline)
  end
end
