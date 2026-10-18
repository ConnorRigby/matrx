defmodule Matrx.API.DeviceKeys do
  @moduledoc """
  Response of `/keys/query`. Device objects are kept exactly as received
  (string keys), since their signatures are checked against the original JSON.
  """

  defstruct device_keys: %{},
            failures: %{},
            master_keys: %{},
            self_signing_keys: %{},
            user_signing_keys: %{}

  def from_response(response) do
    %__MODULE__{
      device_keys: response["device_keys"] || %{},
      failures: response["failures"] || %{},
      master_keys: response["master_keys"] || %{},
      self_signing_keys: response["self_signing_keys"] || %{},
      user_signing_keys: response["user_signing_keys"] || %{}
    }
  end
end
