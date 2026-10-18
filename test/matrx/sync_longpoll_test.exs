defmodule Matrx.SyncLongPollTest do
  use Matrx.RepoCase, async: false
  alias Matrx.SyncLongPoll

  @username "matrx_test_acc"
  @password "password1234!"

  setup :registered_session

  test "sync join room", %{session: session, user_id: user_id} do
    {:ok, pid} = start_supervised({SyncLongPoll, [session: session]})
    room_name = "test-room-#{unique_id()}"
    assert {:ok, room} = create_room(session, room_name)
    assert room.room_id
    assert SyncLongPoll.await_sync(pid)
    assert room_pid = Matrx.RoomSupervisor.whereis(room.room_id)
    assert {:ok, _member} = Matrx.Room.fetch_state(room_pid, "m.room.member", user_id)
    assert {:ok, create} = Matrx.Room.fetch_state(room_pid, "m.room.create", "")
    assert create.creator == user_id
    assert {:ok, m_room_name} = Matrx.Room.fetch_state(room_pid, "m.room.name", "")
    assert m_room_name.name == room_name
  end

  test "sync another user join room", %{session: session, user_id: user_id} do
    {:ok, pid} = start_supervised({SyncLongPoll, [session: session]})
    assert {:ok, room} = create_room(session, "test-room-#{unique_id()}")
    assert room.room_id
    assert SyncLongPoll.await_sync(pid)
    assert room_pid = Matrx.RoomSupervisor.whereis(room.room_id)
    {:ok, %{session: session_2, user_id: user_id_2}} = registered_session(%{})
    assert :ok = Matrx.API.join_room(session_2, room.room_id)
    assert SyncLongPoll.await_sync(pid)

    assert {:ok, _member1} = Matrx.Room.fetch_state(room_pid, "m.room.member", user_id)
    assert {:ok, _member2} = Matrx.Room.fetch_state(room_pid, "m.room.member", user_id_2)
  end

  describe "unencrypted messages" do
    setup :room_with_two_members

    test "send room message", %{sessions: [s1, s2], users: [s1_user_id, s2_user_id], room: room} do
      :ok = Matrx.Room.subscribe(room.room_id)
      assert {:ok, _} = send_msg(s1, room, "message 1")
      assert_receive %{type: "m.room.message", sender: ^s1_user_id, content: %{body: "message 1"}}
      assert {:ok, _} = send_msg(s2, room, "message 2")
      assert_receive %{type: "m.room.message", sender: ^s2_user_id, content: %{body: "message 2"}}
    end
  end

  describe "join existing channel" do
    setup :general_testing_room

    test "send messages", %{sessions: [s1, s2], users: [s1_user_id, s2_user_id], room: room} do
      :ok = Matrx.Room.subscribe(room.room_id)
      assert {:ok, _} = send_msg(s1, room, "message 1")
      assert_receive %{type: "m.room.message", sender: ^s1_user_id, content: %{body: "message 1"}}
      assert {:ok, _} = send_msg(s2, room, "message 2")
      assert_receive %{type: "m.room.message", sender: ^s2_user_id, content: %{body: "message 2"}}
    end
  end

  describe "join encrypted channel" do
    setup :general_encrypted_room

    test "send messages", %{sessions: [_s1, _s2], users: [s1_user_id, s2_user_id], room: room} do
      :ok = Matrx.Room.subscribe(room.room_id)
      assert room_pid = Matrx.RoomSupervisor.whereis(room.room_id)
      assert {:ok, _member1} = Matrx.Room.fetch_state(room_pid, "m.room.member", s1_user_id)
      assert {:ok, _member2} = Matrx.Room.fetch_state(room_pid, "m.room.member", s2_user_id)
      IO.inspect(Matrx.Room.dump_state(room_pid), label: "dump", pretty: true, limit: :infinity)
      assert {:ok, encryption} = Matrx.Room.fetch_state(room_pid, "m.room.encryption", "")
      assert_receive :flunk
    end
  end

  describe "kick members from existing channel" do
    setup :create_admin_session

    test "kick users", %{
      sessions: [s1, _s2],
      users: [_s1_user_id, s2_user_id],
      room: room,
      sync: pid
    } do
      assert room_pid = Matrx.RoomSupervisor.whereis(room.room_id)

      assert {:ok, %{membership: :join}} =
               Matrx.Room.fetch_state(room_pid, "m.room.member", s2_user_id)

      assert :ok =
               Matrx.API.kick_room(s1, room.room_id, %{user_id: s2_user_id, reason: "i hate you"})

      assert SyncLongPoll.await_sync(pid)

      assert {:ok, %{membership: :leave}} =
               Matrx.Room.fetch_state(room_pid, "m.room.member", s2_user_id)
    end
  end

  defp unique_id, do: Ecto.UUID.generate()

  defp send_msg(session, room, body) do
    Matrx.API.send_room_message(session, room.room_id, unique_id(), "m.room.message", %{
      msgtype: "m.text",
      body: body
    })
  end

  defp create_room(session, name) do
    Matrx.API.create_room(session, %{
      name: name,
      preset: :public_chat
    })
  end

  defp register(session, username, account) do
    Matrx.API.register(session, %{
      username: username,
      password: @password,
      device_id: account.id
    })
  end

  defp login(session, username) do
    Matrx.API.login_password(session, %{type: "m.id.user", user: username}, @password)
  end

  defp create_session(account) do
    %{
      home_server_uri: URI.parse("http://big-bug1.local:8888"),
      access_token: nil,
      account: account
    }
  end

  defp registered_session(_tags) do
    username = "#{@username}_#{unique_id()}"
    {:ok, account} = Matrx.Olm.create_account()
    session = create_session(account)
    assert {:ok, %{access_token: access_token}} = register(session, username, account)
    session = %{session | access_token: access_token}
    {:ok, %{session: session, user_id: "@#{username}:#{session.home_server_uri.host}"}}
  end

  def room_with_two_members(tags) do
    {:ok, %{session: s1, user_id: s1_user_id}} = registered_session(tags)
    {:ok, pid} = start_supervised({SyncLongPoll, [session: s1]})
    assert {:ok, room} = create_room(s1, "test-room-#{unique_id()}")
    {:ok, %{session: s2, user_id: s2_user_id}} = registered_session(tags)
    assert :ok = Matrx.API.join_room(s2, room.room_id)
    assert room.room_id
    assert SyncLongPoll.await_sync(pid)
    assert is_pid(Matrx.RoomSupervisor.whereis(room.room_id))
    {:ok, sessions: [s1, s2], users: [s1_user_id, s2_user_id], room: room, sync: pid}
  end

  def general_testing_room(tags) do
    room = %{room_id: "!ekEXc8ADJ9OjekElrbVCrDx-Ebj2vEEwP7Kl3c8uEg8"}

    {:ok, %{session: s1, user_id: s1_user_id}} = registered_session(tags)
    assert :ok = Matrx.API.join_room(s1, room.room_id)
    {:ok, pid} = start_supervised({SyncLongPoll, [session: s1]})

    {:ok, %{session: s2, user_id: s2_user_id}} = registered_session(tags)
    assert :ok = Matrx.API.join_room(s2, room.room_id)
    assert SyncLongPoll.await_sync(pid)
    {:ok, sessions: [s1, s2], users: [s1_user_id, s2_user_id], room: room, sync: pid}
  end

  def general_encrypted_room(tags) do
    room = %{room_id: "!YMJHozDnYGLbLslhRe:big-bug1.local"}

    {:ok, %{session: s1, user_id: s1_user_id}} = registered_session(tags)
    assert :ok = Matrx.API.join_room(s1, room.room_id)
    {:ok, pid} = start_supervised({SyncLongPoll, [session: s1]})

    {:ok, %{session: s2, user_id: s2_user_id}} = registered_session(tags)
    assert :ok = Matrx.API.join_room(s2, room.room_id)
    assert SyncLongPoll.await_sync(pid)
    {:ok, sessions: [s1, s2], users: [s1_user_id, s2_user_id], room: room, sync: pid}
  end

  def create_admin_session(tags) do
    room = %{room_id: "!ekEXc8ADJ9OjekElrbVCrDx-Ebj2vEEwP7Kl3c8uEg8"}

    {:ok, account} = Matrx.Olm.create_account()
    s1 = create_session(account)
    {:ok, %{access_token: access_token}} = login(s1, "admin")

    s1 = %{s1 | access_token: access_token}
    assert :ok = Matrx.API.join_room(s1, room.room_id)

    {:ok, %{session: s2, user_id: s2_user_id}} = registered_session(tags)
    {:ok, pid} = start_supervised({SyncLongPoll, [session: s2]})
    assert :ok = Matrx.API.join_room(s2, room.room_id)
    assert SyncLongPoll.await_sync(pid)

    try do
      SyncLongPoll.await_sync(pid, 1000)
    catch
      :exit, _ -> :ok
    end

    assert is_pid(Matrx.RoomSupervisor.whereis(room.room_id))
    {:ok, sessions: [s1, s2], users: ["@admin:big-bug1.local", s2_user_id], room: room, sync: pid}
  end
end
