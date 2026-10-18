defmodule Matrx.API.Event.RoomCreate do
  defstruct [:creator, :room_version]

  def from_response(content) do
    %__MODULE__{
      creator: content["creator"],
      room_version: content["room_version"]
    }
  end
end
