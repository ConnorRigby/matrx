defmodule Matrx.API.Event.RoomEncryption do
  defstruct [:algorithm]

  def from_response(content) do
    %__MODULE__{
      algorithm: content["algorithm"]
    }
  end
end
