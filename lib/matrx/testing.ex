defmodule Matrx.Testing do
  @username "matrx_test_acc"
  @password "password1234!"

  defp create_session(account) do
    %{
      home_server_uri: URI.parse("http://big-bug1.local:8888"),
      access_token: nil,
      account: account
    }
  end

  def registered_session() do
    room = %{room_id: "!ekEXc8ADJ9OjekElrbVCrDx-Ebj2vEEwP7Kl3c8uEg8"}
    username = "#{@username}_#{unique_id()}"
    {:ok, account} = Matrx.Olm.create_account()
    session = create_session(account)
    {:ok, %{access_token: access_token}} = register(session, username, account)
    session = %{session | access_token: access_token}
    {:ok, sync} = Matrx.SyncLongPoll.start_link(session: session)
    :ok = Matrx.API.join_room(session, room.room_id)

    {:ok,
     %{
       room: room,
       sync: sync,
       session: session,
       user_id: "@#{username}:#{session.home_server_uri.host}"
     }}
  end

  def register(session, username, _account) do
    {:ok, _} =
      Matrx.API.register(session, %{
        username: username,
        password: @password
      })
  end

  def login(session, username) do
    {:ok, _} = Matrx.API.login_password(session, %{type: "m.id.user", user: username}, @password)
  end

  defp unique_id, do: Ecto.UUID.generate()
end
