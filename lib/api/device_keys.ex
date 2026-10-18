defmodule Matrx.API.DeviceKeys do
  defstruct [:device_keys]

  def from_response(%{"device_keys" => device_keys}) do
    device_keys =
      Map.new(device_keys, fn {user_id, keys} ->
        {user_id,
         Map.new(keys, fn {key_id, key} ->
           {key_id,
            %{
              algorithms: key["algorithms"],
              device_id: key["device_id"],
              keys: key["keys"]
            }}
         end)}
      end)

    %__MODULE__{device_keys: device_keys}
  end
end
