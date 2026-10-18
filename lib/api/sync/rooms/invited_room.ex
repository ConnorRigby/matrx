defmodule Matrx.API.Sync.Rooms.InvitedRoom do
  alias Matrx.API.Sync.Rooms.StrippedStateEvent
  defstruct [:invite_state]

  def from_response(invite) do
    events =
      Enum.map(
        invite["invite_state"]["events"],
        &StrippedStateEvent.from_response/1
      )

    %{invite_state: %{events: events}}
  end
end
