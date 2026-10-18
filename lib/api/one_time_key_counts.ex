defmodule Matrx.API.OneTimeKeyCounts do
  defstruct [:one_time_key_counts]

  def from_response(%{"one_time_key_counts" => %{"signed_curve25519" => count}}) do
    %__MODULE__{one_time_key_counts: %{signed_curve25519: count}}
  end
end
