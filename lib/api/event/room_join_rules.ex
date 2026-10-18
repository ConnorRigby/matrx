defmodule Matrx.API.Event.RoomJoinRules do
  defstruct [:allow, :join_rule]

  def from_response(content) do
    allow = if content["allow"], do: allow_condition_from_response(content.allow)

    %__MODULE__{
      allow: allow,
      join_rule: join_rule_from_response(content["join_rule"])
    }
  end

  defp allow_condition_from_response(allow_condition) do
    %{room_id: allow_condition["room_id"], type: allow_condition["type"]}
  end

  defp join_rule_from_response("public"), do: :public
  defp join_rule_from_response("knock"), do: :knock
  defp join_rule_from_response("invite"), do: :invite
  defp join_rule_from_response("private"), do: :private
  defp join_rule_from_response("restricted"), do: :restricted
  defp join_rule_from_response("knock_restricted"), do: :knock_restricted
end
