defmodule Matrx.API.Event.RoomKey do
  defstruct [:algorithm, :"m.shared_history", :room_id, :session_id, :session_key]

  def from_response(response) do
    %__MODULE__{
      algorithm: response["algorithm"],
      room_id: response["room_id"],
      session_id: response["session_id"],
      session_key: response["session_key"],
      "m.shared_history": response["m.shared_history"]
    }
  end
end
