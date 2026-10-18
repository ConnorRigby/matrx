defmodule Matrx.API.ClaimKeys do
  @moduledoc """
  Response of `/keys/claim`. Claimed key objects are kept exactly as received
  (string keys, e.g. `%{"key" => ..., "signatures" => ..., "fallback" => true}`)
  because their signatures are verified against the original JSON.
  """

  defstruct failures: %{}, one_time_keys: %{}

  @type t :: %__MODULE__{}

  def from_response(response) do
    %__MODULE__{
      failures: response["failures"] || %{},
      one_time_keys: response["one_time_keys"] || %{}
    }
  end
end
