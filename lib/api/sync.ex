defmodule Matrx.API.Sync do
  defstruct [
    :account_data,
    :device_one_time_keys_count,
    :device_unused_fallback_key_types,
    :next_batch,
    :presence,
    :rooms,
    :to_device,
    :device_lists
  ]

  alias Matrx.API.Sync.{
    AccountData,
    DeviceOneTimeKeyCounts,
    Presence,
    Rooms,
    ToDevice,
    DeviceLists
  }

  def from_response(response) do
    account_data =
      if response["account_data"], do: AccountData.from_response(response["account_data"])

    device_one_time_keys_count =
      if response["device_one_time_keys_count"],
        do: DeviceOneTimeKeyCounts.from_response(response["device_one_time_keys_count"])

    presence =
      if response["presence"], do: Presence.from_response(response["presence"])

    rooms =
      if response["rooms"], do: Rooms.from_response(response["rooms"])

    to_device =
      if response["to_device"], do: ToDevice.from_response(response["to_device"])

    device_lists =
      if response["device_lists"], do: DeviceLists.from_response(response["device_lists"])

    %__MODULE__{
      account_data: account_data,
      device_one_time_keys_count: device_one_time_keys_count,
      # device_unused_fallback_key_types: device_one_time_keys_count,
      next_batch: response["next_batch"],
      presence: presence,
      rooms: rooms,
      to_device: to_device,
      device_lists: device_lists
    }
  end
end
