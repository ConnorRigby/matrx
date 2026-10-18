defmodule Matrx.API.Sync.Rooms.KnockedRoom do
  alias Matrx.API.Sync.Rooms.StrippedStateEvent

  defstruct [:knock_state]

  def from_response(invite) do
    events =
      Enum.map(
        invite["knock_state"]["events"],
        &StrippedStateEvent.from_response/1
      )

    %{knock_state: %{events: events}}
  end
end
