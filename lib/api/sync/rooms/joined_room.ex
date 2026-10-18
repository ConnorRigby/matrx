defmodule Matrx.API.Sync.Rooms.JoinedRoom do
  alias Matrx.API.Event
  alias Matrx.API.Sync.AccountData
  defstruct [:account_data, :ephemeral, :state, :summary, :timeline, :unread_notifications]

  defmodule UnreadNotifications do
    defstruct [:highlight_count, :notification_count]

    def from_response(%{
          "highlight_count" => highlight_count,
          "notification_count" => notification_count
        }) do
      %__MODULE__{
        highlight_count: highlight_count,
        notification_count: notification_count
      }
    end
  end

  def from_response(response) do
    account_data =
      if response["account_data"], do: AccountData.from_response(response["account_data"])

    unread_notifications =
      if response["unread_notifications"],
        do: UnreadNotifications.from_response(response["unread_notifications"])

    %__MODULE__{
      account_data: account_data,
      ephemeral: response["ephemeral"],
      state: response["state"],
      summary: response["summary"],
      timeline: timeline_from_response(response["timeline"]),
      unread_notifications: unread_notifications
    }
  end

  defp timeline_from_response(%{"events" => events} = timeline) do
    %{
      events: Enum.map(events, &Event.from_response/1),
      limited: timeline["limited"],
      prev_batch: timeline["prev_batch"]
    }
  end
end
