defmodule Matrx.InviteTest do
  # The sync process uses the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false
  @moduletag :capture_log

  alias Matrx.Support.FakeAPI
  alias Matrx.{Consumer, Invite, Session, SyncLongPoll}

  defmodule Handler do
    @behaviour Matrx.Consumer

    @impl true
    def handle_event(event),
      do: send(Application.fetch_env!(:matrx, :invite_test_pid), {:handled, event})
  end

  setup do
    Application.put_env(:matrx, :invite_test_pid, self())
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, bot} = Session.register(uri, %{username: "bot", password: "pw"}, api: FakeAPI)
    {:ok, feed: feed, bot: bot, host: host}
  end

  defp invite_sync(ctx, room_id, inviter, extra_events \\ []) do
    member = %{
      "type" => "m.room.member",
      "state_key" => ctx.bot.user_id,
      "sender" => inviter,
      "content" => %{"membership" => "invite", "is_direct" => true}
    }

    FakeAPI.push_sync(ctx.feed, %{
      "next_batch" => "s#{System.unique_integer([:positive])}",
      "rooms" => %{
        "invite" => %{room_id => %{"invite_state" => %{"events" => [member | extra_events]}}}
      }
    })
  end

  defp start(ctx, consumer_opts) do
    start_supervised!({SyncLongPoll, [session: ctx.bot, api: FakeAPI]})

    start_supervised!(
      {Consumer, [handler: Handler, session: ctx.bot, api: FakeAPI] ++ consumer_opts}
    )
  end

  test "an invite reaches the handler without creating a room", ctx do
    start(ctx, [])
    room_id = "!r1:#{ctx.host}"

    name = %{
      "type" => "m.room.name",
      "state_key" => "",
      "sender" => "@alice:x",
      "content" => %{"name" => "Party"}
    }

    invite_sync(ctx, room_id, "@alice:x", [name])

    assert_receive {:handled, {:room_invite, %Invite{} = invite, context}}, 2000
    assert invite.room_id == room_id
    assert invite.user_id == ctx.bot.user_id
    assert invite.inviter == "@alice:x"
    assert invite.room_name == "Party"
    assert invite.is_direct
    assert context.session.id == ctx.bot.id

    refute Matrx.RoomSupervisor.whereis(room_id)
    refute_receive {:join_room, _, _}, 100
  end

  test "does not join unless asked to", ctx do
    start(ctx, [])
    invite_sync(ctx, "!r2:#{ctx.host}", "@alice:x")
    assert_receive {:handled, {:room_invite, _, _}}, 2000
    refute_receive {:join_room, _, _}, 200
  end

  test "auto_join: true accepts every invite", ctx do
    start(ctx, auto_join: true)
    room_id = "!r3:#{ctx.host}"
    invite_sync(ctx, room_id, "@alice:x")

    user = ctx.bot.user_id
    assert_receive {:join_room, ^user, ^room_id}, 2000
    assert_receive {:handled, {:room_invite, _, _}}
  end

  test "auto_join with a function only accepts approved invites", ctx do
    start(ctx, auto_join: &(&1.inviter == "@admin:x"))
    ok_room = "!ok:#{ctx.host}"
    no_room = "!no:#{ctx.host}"

    invite_sync(ctx, no_room, "@stranger:x")
    assert_receive {:handled, {:room_invite, %{room_id: ^no_room}, _}}, 2000
    refute_receive {:join_room, _, ^no_room}, 200

    invite_sync(ctx, ok_room, "@admin:x")
    assert_receive {:join_room, _, ^ok_room}, 2000
  end

  test "invites of another user are ignored", ctx do
    start(ctx, auto_join: true)
    invited = Matrx.API.Sync.Rooms.InvitedRoom.from_response(%{})

    Matrx.Room.broadcast_invite("@someone:else", "!other:#{ctx.host}", invited)

    refute_receive {:handled, {:room_invite, _, _}}, 200
    refute_receive {:join_room, _, _}, 100
  end

  test "an invite without state still parses" do
    invite = Invite.from_sync("@a:b", "!r:b", Matrx.API.Sync.Rooms.InvitedRoom.from_response(%{}))
    assert %Invite{inviter: nil, room_name: nil, is_direct: false, state: []} = invite
  end

  test "accept/3 and decline/3 call the server", ctx do
    invite = %Invite{room_id: "!x:y", user_id: ctx.bot.user_id}
    user = ctx.bot.user_id
    assert :ok = Invite.accept(ctx.bot, invite, api: FakeAPI)
    assert_receive {:join_room, ^user, "!x:y"}
    assert :ok = Invite.decline(ctx.bot, invite, api: FakeAPI)
    assert_receive {:leave_room, ^user, "!x:y"}
  end

  test "Client passes auto_join through", ctx do
    opts = [
      handler: Handler,
      homeserver: "http://#{ctx.host}",
      username: "bot",
      api: FakeAPI,
      migrate: false,
      auto_join: true
    ]

    start_supervised!({Matrx.Client, opts})
    room_id = "!viaclient:#{ctx.host}"
    invite_sync(ctx, room_id, "@alice:x")
    assert_receive {:join_room, _, ^room_id}, 2000
  end
end
