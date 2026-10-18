defmodule Matrx.API.Event.RoomPowerLevels do
  defstruct [
    :ban,
    :events,
    :events_default,
    :historical,
    :invite,
    :kick,
    :redact,
    :state_default,
    :users,
    :users_default,
    :"m.call.invite"
  ]

  def from_response(content) do
    %__MODULE__{
      ban: content["ban"],
      events: content["events"],
      events_default: content["events_default"],
      historical: content["historical"],
      invite: content["invite"],
      kick: content["kick"],
      redact: content["redact"],
      state_default: content["state_default"],
      users: content["users"],
      users_default: content["users_default"],
      "m.call.invite": content["m.call.invite"]
    }
  end
end
