defmodule Matrx.API.Event.RoomEncrypted do
  defstruct [:algorithm, :device_id, :ciphertext, :sender_key, :session_id]

  def from_response(%{"ciphertext" => %{}} = content) do
    ciphertext =
      Map.new(content["ciphertext"], fn {key_id, ciphertext} ->
        {key_id,
         %{
           body: ciphertext["body"],
           type: ciphertext["type"]
         }}
      end)

    %__MODULE__{
      algorithm: content["algorithm"],
      device_id: content["device_id"],
      ciphertext: ciphertext,
      sender_key: content["sender_key"],
      session_id: content["session_id"]
    }
  end

  def from_response(content) do
    %__MODULE__{
      algorithm: content["algorithm"],
      device_id: content["device_id"],
      ciphertext: content["ciphertext"],
      sender_key: content["sender_key"],
      session_id: content["session_id"]
    }
  end
end
