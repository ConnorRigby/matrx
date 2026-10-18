defmodule Matrx.DevTest do
  use Matrx.RepoCase, async: false

  import ExUnit.CaptureIO
  alias Matrx.Dev
  alias Matrx.Support.FakeAPI

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    on_exit(&Dev.stop_sync/0)
    {:ok, feed: feed, url: "http://#{host}"}
  end

  test "connect logs in once, then reuses the stored device", %{url: url} do
    first = Dev.connect(url, "alice", password: "pw", api: FakeAPI)
    assert Dev.syncing?()

    second = Dev.connect(url, "alice", password: "pw", api: FakeAPI)
    assert second.id == first.id
    assert Repo.aggregate(Matrx.Session, :count) == 1

    third = Dev.connect(url, "alice", password: "pw", api: FakeAPI, new_device: true)
    assert third.id != first.id
  end

  test "connect needs a password for a first login", %{url: url} do
    System.delete_env("MATRIX_PASSWORD")

    assert_raise ArgumentError, ~r/MATRIX_PASSWORD/, fn ->
      Dev.connect(url, "alice", api: FakeAPI)
    end
  end

  test "say and watch work on an encrypted room", %{feed: feed, url: url} do
    alice = Dev.connect(url, "alice", password: "pw", api: FakeAPI)
    room_id = "!dev#{System.unique_integer([:positive])}:example.org"

    state = fn type, key, content ->
      %{
        "type" => type,
        "state_key" => key,
        "sender" => "@x:y",
        "event_id" => "$#{System.unique_integer([:positive])}",
        "origin_server_ts" => 1,
        "content" => content
      }
    end

    FakeAPI.push_sync(feed, %{
      "next_batch" => "s1",
      "rooms" => %{
        "join" => %{
          room_id => %{
            "state" => %{
              "events" => [
                state.("m.room.encryption", "", %{"algorithm" => "m.megolm.v1.aes-sha2"}),
                state.("m.room.member", alice.user_id, %{"membership" => "join"})
              ]
            },
            "timeline" => %{"events" => []}
          }
        }
      }
    })

    Dev.await_sync()

    # await_sync replies as soon as the sync arrives, before its rooms are handled
    Enum.find_value(1..100, fn _ ->
      Process.sleep(20)
      Enum.any?(Dev.rooms(), &(&1.room_id == room_id and &1.encrypted)) || nil
    end) || flunk("room never arrived")

    assert Enum.any?(Dev.rooms(), &(&1.room_id == room_id and &1.encrypted))

    assert {:ok, %{event_id: _}} = Dev.say(alice, room_id, "hi", api: FakeAPI)
    assert_receive {:send_room_message, ^room_id, "m.room.encrypted", _}
  end

  test "format prints messages, waiting events and others" do
    msg = %Matrx.API.Event{type: "m.room.message", sender: "@a:b", content: %{body: "hey"}}
    assert Dev.format("!r", msg) == "@a:b: hey"

    assert Dev.format("!r", %{type: "m.room.encrypted", sender: "@a:b", event_id: "$1"}) =~
             "waiting"

    assert Dev.format("!r", %{type: "m.typing", sender: "@a:b"}) == "@a:b: <m.typing>"
  end

  test "watch prints events delivered to the room" do
    room_id = "!watch#{System.unique_integer([:positive])}:example.org"

    output =
      capture_io(fn ->
        pid = Dev.watch(room_id)
        Process.sleep(50)

        Matrx.Room.broadcast_event(room_id, %Matrx.API.Event{
          type: "m.room.message",
          sender: "@a:b",
          content: %{body: "yo"}
        })

        Process.sleep(100)
        Process.exit(pid, :kill)
      end)

    assert output =~ "@a:b: yo"
  end

  test "clear_other_data removes everything not owned by the session", %{url: url} do
    old = Dev.connect(url, "alice", password: "pw", api: FakeAPI)
    {:ok, old_outbound} = Matrx.Megolm.create_outbound_session(%{owner_id: old.id})

    {:ok, old_inbound} =
      Matrx.Megolm.create_inbound_session(old_outbound.session_id, old_outbound.session_key, %{
        owner_id: old.id
      })

    Repo.insert!(%Matrx.Megolm.MessageIndex{
      session_id: old_inbound.session_id,
      message_index: 0,
      event_id: "$e"
    })

    :ok = Matrx.Crypto.CrossSigning.bootstrap(old, api: FakeAPI, reset: true)

    current = Dev.connect(url, "alice", password: "pw", api: FakeAPI, new_device: true)
    {:ok, kept} = Matrx.Megolm.create_outbound_session(%{owner_id: current.id})
    {:ok, orphan} = Matrx.Megolm.create_outbound_session()

    assert {:ok, 1} = Dev.clear_other_data(current)

    assert [%{id: id}] = Repo.all(Matrx.Session)
    assert id == current.id
    assert Repo.aggregate(Matrx.Olm.Account, :count) == 1
    assert Repo.aggregate(Matrx.Crypto.CrossSigningKey, :count) == 0
    assert Repo.aggregate(Matrx.Megolm.InboundSession, :count) == 0
    assert Repo.aggregate(Matrx.Megolm.MessageIndex, :count) == 0
    assert [%{session_id: sid}] = Repo.all(Matrx.Megolm.OutboundSession)
    assert sid == kept.session_id
    refute sid == orphan.session_id
  end

  test "clear_remote_data deletes other devices and replaces the cross-signing keys", %{
    feed: feed,
    url: url
  } do
    other = Dev.connect(url, "alice", password: "pw", api: FakeAPI, new_device: true)
    current = Dev.connect(url, "alice", password: "pw", api: FakeAPI, new_device: true)
    :ok = Matrx.Crypto.CrossSigning.bootstrap(other, api: FakeAPI)
    assert_received {:upload_signing_keys, _, %{"master_key" => old_master}}
    FakeAPI.require_uia(feed, "pw")

    assert {:error, :password_required} =
             Dev.clear_remote_data(current, api: FakeAPI, password: nil)

    refute_received {:delete_devices, _, _}

    assert {:ok, [id]} = Dev.clear_remote_data(current, api: FakeAPI, password: "pw")
    assert id == other.device_id
    assert_received {:delete_devices, _, [^id]}
    assert_received {:upload_signing_keys, _, %{"master_key" => new_master}}
    refute new_master == old_master
    assert {:ok, [%{"device_id" => current_id}]} = FakeAPI.list_devices(current)
    assert current_id == current.device_id
    assert Matrx.Crypto.Devices.trusted?(current, current.user_id, current.device_id)
  end
end
