defmodule Matrx.API.Event.RoomMessage do
  defstruct [:body, :"m.mentions", :msgtype]

  def from_response(response) do
    mentions = if response["m.mentions"], do: mentions_from_response(response["m.mentions"])

    %__MODULE__{
      body: response["body"],
      msgtype: response["msgtype"],
      "m.mentions": mentions
    }
  end

  defp mentions_from_response(%{"user_ids" => user_ids}) do
    %{user_ids: user_ids}
  end

  defp mentions_from_response(%{}) do
    nil
  end
end
