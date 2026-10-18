defmodule Matrx.API.Event.RoomName do
  defstruct [:name]

  def from_response(content) do
    %__MODULE__{name: content["name"]}
  end
end
