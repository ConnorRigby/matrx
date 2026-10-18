defmodule Matrx.API.Sync.ToDevice do
  alias Matrx.API.Event

  defstruct [:events]

  def from_response(%{"events" => events}) do
    %__MODULE__{events: Enum.map(events, &Event.from_response/1)}
  end
end
