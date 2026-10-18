defmodule Matrx.API.Event.RoomMember do
  defstruct [:avatar_url, :displayname, :membership]

  def from_response(content) do
    %__MODULE__{
      avatar_url: content["avatar_url"],
      displayname: content["displayname"],
      membership: membership_from_response(content["membership"])
    }
  end

  defp membership_from_response("leave"), do: :leave
  defp membership_from_response("join"), do: :join
end
