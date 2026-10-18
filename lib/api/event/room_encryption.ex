defmodule Matrx.API.Event.RoomEncryption do
  defstruct [:algorithm, :rotation_period_ms, :rotation_period_msgs]

  def from_response(content) do
    %__MODULE__{
      algorithm: content["algorithm"],
      rotation_period_ms: content["rotation_period_ms"],
      rotation_period_msgs: content["rotation_period_msgs"]
    }
  end
end
