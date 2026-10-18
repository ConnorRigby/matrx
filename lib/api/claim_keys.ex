defmodule Matrx.API.ClaimKeys do
  defstruct [:failures, :one_time_keys]

  def from_response(response) do
    failures = if response["failures"], do: failures_from_response(response["failures"])

    one_time_keys =
      if response["one_time_keys"], do: one_time_keys_from_response(response["one_time_keys"])

    %__MODULE__{
      failures: failures,
      one_time_keys: one_time_keys
    }
  end

  def failures_from_response(failures) do
    Map.new(failures, fn {homeserver, failure} ->
      {homeserver, %{message: failure["message"], status: failure["status"]}}
    end)
  end

  def one_time_keys_from_response(one_time_keys) do
    Map.new(one_time_keys, fn {user_id, keys} ->
      {user_id,
       Map.new(
         keys,
         fn {device_id, keys} ->
           {device_id,
            Map.new(keys, fn {key_id, key} ->
              {key_id, %{key: key["key"], signatures: key["signatures"]}}
            end)}
         end
       )}
    end)
  end
end
