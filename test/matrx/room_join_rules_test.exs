defmodule Matrx.API.Event.RoomJoinRulesTest do
  use ExUnit.Case, async: true
  alias Matrx.API.Event.RoomJoinRules

  test "parses the allow list of a restricted room" do
    rules =
      RoomJoinRules.from_response(%{
        "join_rule" => "restricted",
        "allow" => [%{"type" => "m.room_membership", "room_id" => "!a:b"}]
      })

    assert rules.join_rule == :restricted
    assert rules.allow == [%{type: "m.room_membership", room_id: "!a:b"}]
  end

  test "keeps unknown join rules instead of crashing" do
    assert %{join_rule: "custom", allow: nil} =
             RoomJoinRules.from_response(%{"join_rule" => "custom"})
  end
end
