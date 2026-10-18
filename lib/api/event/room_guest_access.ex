defmodule Matrx.API.Event.RoomGuestAccess do
  defstruct [:guest_access]

  def from_response(content) do
    %__MODULE__{
      guest_access: guest_access_from_response(content["guest_access"])
    }
  end

  defp guest_access_from_response("can_join"), do: :can_join
  defp guest_access_from_response("forbidden"), do: :forbidden
end
