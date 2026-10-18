defmodule Matrx.API.Sync.DeviceOneTimeKeyCounts do
  defstruct [:signed_curve25519]

  def from_response(%{"signed_curve25519" => count}) do
    %__MODULE__{signed_curve25519: count}
  end
end
