defmodule Matrx.API.OneTimeKeyCounts do
  defstruct [:one_time_key_counts]

  @type t :: %__MODULE__{}

  def from_response(response) do
    counts = response["one_time_key_counts"] || %{}
    %__MODULE__{one_time_key_counts: %{signed_curve25519: counts["signed_curve25519"] || 0}}
  end
end
