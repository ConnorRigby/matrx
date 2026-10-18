defmodule Matrx.API.Sync.Rooms.LeftRoom do
  defstruct [:account_data, :state, :state_after, :timeline]
  alias Matrx.API.Event
  alias Matrx.API.Sync.AccountData

  def from_response(response) do
    account_data =
      if response["account_data"], do: AccountData.from_response(response["account_data"])

    %__MODULE__{
      account_data: account_data,
      state: state_from_response(response["state"]),
      state_after: response["state_after"],
      timeline: timeline_from_response(response["timeline"])
    }
  end

  defp timeline_from_response(%{"events" => events} = timeline) do
    %{
      events: Enum.map(events, &Event.from_response/1),
      limited: timeline["limited"],
      prev_batch: timeline["prev_batch"]
    }
  end

  defp state_from_response(%{"events" => events}),
    do: %{events: Enum.map(events, &Event.from_response/1)}

  defp state_from_response(_), do: %{events: []}
end
