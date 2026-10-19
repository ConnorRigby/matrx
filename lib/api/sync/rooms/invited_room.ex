defmodule Matrx.API.Sync.Rooms.InvitedRoom do
  alias Matrx.API.Sync.Rooms.StrippedStateEvent
  defstruct invite_state: %{events: []}

  @type t :: %__MODULE__{invite_state: %{events: [StrippedStateEvent.t()]}}

  def from_response(invite) do
    events =
      invite
      |> get_in(["invite_state", "events"])
      |> List.wrap()
      |> Enum.map(&StrippedStateEvent.from_response/1)

    %__MODULE__{invite_state: %{events: events}}
  end
end
