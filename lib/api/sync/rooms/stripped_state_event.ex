defmodule Matrx.API.Sync.Rooms.StrippedStateEvent do
  alias Matrx.API.Event
  defstruct [:content, :sender, :state_key, :type]

  def from_response(stripped_state_event) do
    type = stripped_state_event["type"]
    content = stripped_state_event["content"]
    sender = stripped_state_event["sender"]
    state_key = stripped_state_event["state_key"]

    %__MODULE__{
      content: Event.content_from_response(type, content),
      sender: sender,
      state_key: state_key,
      type: type
    }
  end
end
