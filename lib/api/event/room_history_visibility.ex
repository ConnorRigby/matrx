defmodule Matrx.API.Event.RoomHistoryVisibility do
  defstruct [:history_visibility]

  def from_response(content) do
    history_visibility = history_visibility_from_response(content["history_visibility"])
    %__MODULE__{history_visibility: history_visibility}
  end

  defp history_visibility_from_response("world_readable"), do: :world_readable
  defp history_visibility_from_response("shared"), do: :shared
  defp history_visibility_from_response("invited"), do: :invited
  defp history_visibility_from_response("joined"), do: :joined
end
