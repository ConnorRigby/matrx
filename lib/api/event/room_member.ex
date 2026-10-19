defmodule Matrx.API.Event.RoomMember do
  defstruct [:avatar_url, :displayname, :membership, :is_direct]

  def from_response(content) do
    %__MODULE__{
      avatar_url: content["avatar_url"],
      displayname: content["displayname"],
      is_direct: content["is_direct"] == true,
      membership: membership_from_response(content["membership"])
    }
  end

  defp membership_from_response("leave"), do: :leave
  defp membership_from_response("join"), do: :join
  defp membership_from_response("invite"), do: :invite
  defp membership_from_response("knock"), do: :knock
  defp membership_from_response("ban"), do: :ban
end
