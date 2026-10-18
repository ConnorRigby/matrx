defmodule Matrx.SyncLongPollKeysTest do
  # The sync process touches the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false

  alias Matrx.Support.FakeAPI
  alias Matrx.{Session, SyncLongPoll}

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)

    {:ok, session} =
      Session.register(URI.parse("http://#{host}"), %{username: "alice", password: "pw"},
        api: FakeAPI
      )

    assert_receive {:upload_keys, _}
    {:ok, feed: feed, session: session}
  end

  defp start_sync(session),
    do: start_supervised!({SyncLongPoll, [session: session, api: FakeAPI]})

  defp push(feed, count) do
    FakeAPI.push_sync(feed, %{
      "next_batch" => "s#{System.unique_integer([:positive])}",
      "device_one_time_keys_count" => %{"signed_curve25519" => count}
    })
  end

  test "uploads more keys when the server count is low", %{feed: feed, session: session} do
    start_sync(session)
    push(feed, 10)
    assert_receive {:upload_keys, body}
    refute Map.has_key?(body, "device_keys")
    assert map_size(body["one_time_keys"]) == 40
  end

  test "does nothing when the server count is healthy", %{feed: feed, session: session} do
    start_sync(session)
    push(feed, 50)
    refute_receive {:upload_keys, _}, 200
  end

  describe "device lists" do
    alias Matrx.Crypto.{Devices, Keys}
    alias Matrx.Olm

    defp bobs_device(session) do
      bob = "@bob:#{session.home_server_uri.host}"
      {:ok, account} = Olm.create_account()
      login = %{access_token: "t", device_id: "PHONE", user_id: bob}
      {:ok, bob_session} = Session.create(session.home_server_uri, account, login)
      {bob, Keys.device_keys(bob_session)}
    end

    defp push_lists(feed, lists) do
      FakeAPI.push_sync(feed, %{
        "next_batch" => "s#{System.unique_integer([:positive])}",
        "device_lists" => lists
      })
    end

    defp wait_for(fun, tries \\ 50) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("condition never became true")
        true -> Process.sleep(20) && wait_for(fun, tries - 1)
      end
    end

    test "changed devices of tracked users are refreshed", %{feed: feed, session: session} do
      {bob, keys} = bobs_device(session)
      FakeAPI.put_device(feed, bob, "PHONE", keys)
      Devices.track(session, [bob])
      start_sync(session)

      push_lists(feed, %{"changed" => [bob]})
      wait_for(fn -> match?([_], Devices.list(session, bob)) end)
      assert Devices.outdated_users(session) == []
    end

    test "changed devices of untracked users are ignored", %{feed: feed, session: session} do
      {bob, keys} = bobs_device(session)
      FakeAPI.put_device(feed, bob, "PHONE", keys)
      pid = start_sync(session)

      push_lists(feed, %{"changed" => [bob]})
      assert SyncLongPoll.await_sync(pid)
      assert Devices.list(session, bob) == []
    end

    test "users in `left` are untracked", %{feed: feed, session: session} do
      {bob, _} = bobs_device(session)
      Devices.track(session, [bob])
      start_sync(session)

      push_lists(feed, %{"left" => [bob]})
      wait_for(fn -> not Devices.tracked?(session, bob) end)
    end

    defp join_room(feed, room_id, members, encrypted?) do
      member_events =
        for {user, membership} <- members do
          %{
            "type" => "m.room.member",
            "state_key" => user,
            "sender" => user,
            "event_id" => "$#{System.unique_integer([:positive])}",
            "origin_server_ts" => 1,
            "content" => %{"membership" => membership}
          }
        end

      encryption =
        if encrypted? do
          [
            %{
              "type" => "m.room.encryption",
              "state_key" => "",
              "sender" => "@a:b",
              "event_id" => "$enc#{System.unique_integer([:positive])}",
              "origin_server_ts" => 1,
              "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}
            }
          ]
        else
          []
        end

      FakeAPI.push_sync(feed, %{
        "next_batch" => "s#{System.unique_integer([:positive])}",
        "rooms" => %{
          "join" => %{
            room_id => %{
              "state" => %{"events" => encryption ++ member_events},
              "timeline" => %{"events" => []}
            }
          }
        }
      })
    end

    test "encrypted room: tracks and fetches devices of joined and invited members", %{
      feed: feed,
      session: session
    } do
      {bob, keys} = bobs_device(session)
      carol = "@carol:#{session.home_server_uri.host}"
      dave = "@dave:#{session.home_server_uri.host}"
      FakeAPI.put_device(feed, bob, "PHONE", keys)
      start_sync(session)

      join_room(
        feed,
        "!enc:example.org",
        [{session.user_id, "join"}, {bob, "join"}, {carol, "invite"}, {dave, "leave"}],
        true
      )

      wait_for(fn -> match?([_], Devices.list(session, bob)) end)
      assert Devices.tracked?(session, carol)
      refute Devices.tracked?(session, dave)
      # our own other devices need the room keys too
      assert Devices.tracked?(session, session.user_id)
    end

    test "encrypted room: ignores unencrypted rooms", %{feed: feed, session: session} do
      {bob, _} = bobs_device(session)
      pid = start_sync(session)

      join_room(feed, "!plain:example.org", [{bob, "join"}], false)
      assert SyncLongPoll.await_sync(pid)
      refute Devices.tracked?(session, bob)
    end

    test "encrypted room: tracks members who join later", %{feed: feed, session: session} do
      {bob, keys} = bobs_device(session)
      FakeAPI.put_device(feed, bob, "PHONE", keys)
      start_sync(session)

      join_room(feed, "!enc:example.org", [{session.user_id, "join"}], true)
      join_room(feed, "!enc:example.org", [{bob, "join"}], false)
      wait_for(fn -> match?([_], Devices.list(session, bob)) end)
    end

    defp leaving_setup(%{feed: feed, session: session}) do
      {bob, keys} = bobs_device(session)
      FakeAPI.put_device(feed, bob, "PHONE", keys)
      start_sync(session)
      {bob, "!enc#{System.unique_integer([:positive])}:example.org"}
    end

    defp tracked_after(session, user, expected) do
      wait_for(fn -> Devices.tracked?(session, user) == expected end)
    end

    test "leaving: untracks a member who leaves", %{feed: feed, session: session} = ctx do
      {bob, room} = leaving_setup(ctx)
      join_room(feed, room, [{session.user_id, "join"}, {bob, "join"}], true)
      tracked_after(session, bob, true)

      join_room(feed, room, [{bob, "leave"}], false)
      tracked_after(session, bob, false)
      assert Devices.tracked?(session, session.user_id)
    end

    test "leaving: keeps tracking a member who shares another encrypted room",
         %{feed: feed, session: session} = ctx do
      {bob, room} = leaving_setup(ctx)
      other = "!other#{System.unique_integer([:positive])}:example.org"
      join_room(feed, room, [{session.user_id, "join"}, {bob, "join"}], true)
      join_room(feed, other, [{session.user_id, "join"}, {bob, "join"}], true)
      tracked_after(session, bob, true)

      join_room(feed, room, [{bob, "leave"}], false)
      # no event to wait for when nothing should change
      Process.sleep(200)
      assert Devices.tracked?(session, bob)
    end

    test "leaving: untracks everyone when we leave the room",
         %{feed: feed, session: session} = ctx do
      {bob, room} = leaving_setup(ctx)
      join_room(feed, room, [{session.user_id, "join"}, {bob, "join"}], true)
      tracked_after(session, bob, true)

      FakeAPI.push_sync(feed, %{
        "next_batch" => "s#{System.unique_integer([:positive])}",
        "rooms" => %{
          "leave" => %{
            room => %{
              "timeline" => %{
                "events" => [
                  %{
                    "type" => "m.room.member",
                    "state_key" => session.user_id,
                    "sender" => session.user_id,
                    "event_id" => "$l#{System.unique_integer([:positive])}",
                    "origin_server_ts" => 1,
                    "content" => %{"membership" => "leave"}
                  }
                ]
              }
            }
          }
        }
      })

      tracked_after(session, bob, false)
    end
  end
end
