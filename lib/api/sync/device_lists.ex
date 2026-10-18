defmodule Matrx.API.Sync.DeviceLists do
  defstruct [:changed, :left]

  def from_response(response) do
    %__MODULE__{changed: response["changed"] || [], left: response["left"] || []}
  end
end
