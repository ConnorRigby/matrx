defmodule Matrx.APIBehaviourTest do
  use ExUnit.Case, async: true

  alias Matrx.Support.FakeAPI

  test "Matrx.API and FakeAPI export every callback" do
    for module <- [Matrx.API, FakeAPI],
        {name, arity} <- Matrx.APIBehaviour.behaviour_info(:callbacks) do
      Code.ensure_loaded!(module)
      assert function_exported?(module, name, arity), "#{inspect(module)} lacks #{name}/#{arity}"
    end
  end

  test "error bodies that are not Matrix errors still parse" do
    assert %Matrx.APIError{errcode: :m_unknown} = Matrx.APIError.from_json("<html>502</html>")

    assert %Matrx.APIError{errcode: :m_limit_exceeded} =
             Matrx.APIError.from_json(%{"errcode" => "M_LIMIT_EXCEEDED", "error" => "slow down"})
  end

  test "FakeAPI room calls are reported to the owner" do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, _feed} = FakeAPI.start_feed(host: host)
    session = %{home_server_uri: URI.parse("http://#{host}"), user_id: "@bot:#{host}"}

    assert {:ok, %{room_id: room_id}} = FakeAPI.create_room(session, %{name: "x"})
    assert :ok = FakeAPI.join_room(session, room_id)
    assert :ok = FakeAPI.kick_room(session, room_id, %{user_id: "@a:b"})
    assert :ok = FakeAPI.leave_room(session, room_id)

    user = session.user_id
    assert_receive {:create_room, ^user, %{name: "x"}}
    assert_receive {:join_room, ^user, ^room_id}
    assert_receive {:kick_room, ^user, ^room_id, %{user_id: "@a:b"}}
    assert_receive {:leave_room, ^user, ^room_id}
  end
end
