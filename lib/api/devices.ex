defmodule Matrx.API.Devices do
  defstruct [:devices]

  def from_response(%{"devices" => devices}) do
    devices =
      Enum.map(devices, fn device ->
        %{
          device_id: device["device_id"],
          display_name: device["display_name"],
          last_seen_ip: device["last_seen_ip"],
          last_seen_ts: device["last_seen_ts"],
          user_id: device["user_id"]
        }
      end)

    %__MODULE__{
      devices: devices
    }
  end
end
