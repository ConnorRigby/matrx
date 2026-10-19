defmodule Matrx.SyncRestartTest do
  use Matrx.RepoCase, async: false
  @moduletag :capture_log

  alias Matrx.Support.FakeAPI
  alias Matrx.{Room, Session, SyncLongPoll}

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)

    {:ok, session} =
      Session.register("http://#{host}", %{username: "bot", password: "pw"}, api: FakeAPI)

    room_id = "!restart:#{host}"
    Room.subscribe(room_id)
    {:ok, session: session, feed: feed, room_id: room_id}
  end

  defp batch(ctx, token, events) do
    FakeAPI.push_sync(ctx.feed, %{
      "next_batch" => token,
      "rooms" => %{
        "join" => %{ctx.room_id => %{"timeline" => %{"events" => events}}}
      }
    })
  end

  defp message(id, body \\ "!ping") do
    %{
      "type" => "m.room.message",
      "event_id" => id,
      "sender" => "@alice:example.org",
      "origin_server_ts" => 1,
      "content" => %{"msgtype" => "m.text", "body" => body}
    }
  end

  defp start(ctx, opts \\ []) do
    start_supervised!(
      {SyncLongPoll, [session: ctx.session, api: FakeAPI, initial_history: false] ++ opts}
    )
  end

  test "skips initial messages, retains state, then resumes offline messages on restart", ctx do
    start(ctx)
    assert_receive {:sync_query, nil}, 1000

    state = %{
      "type" => "m.room.member",
      "state_key" => ctx.session.user_id,
      "sender" => ctx.session.user_id,
      "content" => %{"membership" => "join"}
    }

    batch(ctx, "baseline", [state, message("$old")])
    assert_receive {:sync_query, %{since: "baseline"}}, 1000
    refute_receive %Matrx.API.Event{event_id: "$old"}, 50
    assert Repo.get!(Session, ctx.session.id).sync_token == "baseline"
    room = Matrx.RoomSupervisor.whereis(ctx.room_id)

    assert {:ok, %{membership: :join}} =
             Room.fetch_state(room, "m.room.member", ctx.session.user_id)

    batch(ctx, "live", [message("$live")])
    assert_receive %Matrx.API.Event{event_id: "$live"}, 1000
    assert_receive {:sync_query, %{since: "live"}}, 1000
    :ok = stop_supervised(SyncLongPoll)
    Matrx.RoomSupervisor.stop_room(ctx.room_id)

    start(ctx)
    assert_receive {:sync_query, %{since: "live", full_state: true}}, 1000
    batch(ctx, "offline", [state, message("$old"), message("$live"), message("$offline")])
    assert_receive %Matrx.API.Event{event_id: "$offline"}, 1000
    assert_receive {:sync_query, %{since: "offline"}}, 1000
    refute_receive %Matrx.API.Event{event_id: "$old"}, 50
    refute_receive %Matrx.API.Event{event_id: "$live"}, 50
    assert Repo.get!(Session, ctx.session.id).sync_token == "offline"
  end

  test "duplicate events in the same and later batches are published once", ctx do
    start_supervised!({SyncLongPoll, session: ctx.session, api: FakeAPI})
    batch(ctx, "one", [message("$duplicate"), message("$duplicate")])
    assert_receive %Matrx.API.Event{event_id: "$duplicate"}, 1000
    assert_receive {:sync_query, %{since: "one"}}, 1000
    batch(ctx, "two", [message("$duplicate")])
    assert_receive {:sync_query, %{since: "two"}}, 1000
    refute_receive %Matrx.API.Event{event_id: "$duplicate"}, 50
  end

  test "initial history can be explicitly enabled", ctx do
    start_supervised!({SyncLongPoll, session: ctx.session, api: FakeAPI, initial_history: true})

    batch(ctx, "one", [message("$history")])
    assert_receive %Matrx.API.Event{event_id: "$history"}, 1000
  end

  test "rejects a second sync loop for the same stored session", ctx do
    Process.flag(:trap_exit, true)
    first = start(ctx)

    assert {:error, {:already_syncing, ^first}} =
             SyncLongPoll.start_link(session: ctx.session, api: FakeAPI)

    assert Process.alive?(first)
  end

  test "stopping the sync server also stops its polling worker", ctx do
    sync = start(ctx)
    {worker, _} = :sys.get_state(sync).sync
    monitor = Process.monitor(worker)
    :ok = stop_supervised(SyncLongPoll)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
    refute Process.alive?(worker)
  end

  test "killing the sync server cannot leave its polling worker orphaned", ctx do
    {:ok, sync} = SyncLongPoll.start_link(session: ctx.session, api: FakeAPI)
    Process.unlink(sync)
    {worker, _} = :sys.get_state(sync).sync
    monitor = Process.monitor(worker)
    Process.exit(sync, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1000
  end

  test "does not advance the durable checkpoint while a room key is missing", ctx do
    start(ctx)
    batch(ctx, "baseline", [])
    assert_receive {:sync_query, %{since: "baseline"}}, 1000

    encrypted = %{
      "type" => "m.room.encrypted",
      "event_id" => "$missing",
      "sender" => "@alice:example.org",
      "content" => %{
        "algorithm" => "m.megolm.v1.aes-sha2",
        "session_id" => "unknown",
        "sender_key" => "unknown",
        "ciphertext" => "unknown",
        "device_id" => "UNKNOWN"
      }
    }

    batch(ctx, "pending", [encrypted])
    assert_receive {:sync_query, %{since: "pending"}}, 1000
    assert Repo.get!(Session, ctx.session.id).sync_token == "baseline"
  end
end
