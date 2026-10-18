defmodule Matrx.API.Event do
  @event_modules %{
    "m.room.create" => Matrx.API.Event.RoomCreate,
    "m.room.encrypted" => Matrx.API.Event.RoomEncrypted,
    "m.room.encryption" => Matrx.API.Event.RoomEncryption,
    "m.room.guest_access" => Matrx.API.Event.RoomGuestAccess,
    "m.room.history_visibility" => Matrx.API.Event.RoomHistoryVisibility,
    "m.room.join_rules" => Matrx.API.Event.RoomJoinRules,
    "m.room.member" => Matrx.API.Event.RoomMember,
    "m.room.message" => Matrx.API.Event.RoomMessage,
    "m.room.name" => Matrx.API.Event.RoomName,
    "m.room.power_levels" => Matrx.API.Event.RoomPowerLevels,
    "m.room_key" => Matrx.API.Event.RoomKey
  }

  defstruct [
    :type,
    :event_id,
    :sender,
    :state_key,
    :origin_server_ts,
    :content,
    :unsigned
  ]

  def from_response(%{"type" => type} = event) do
    %__MODULE__{
      type: type,
      event_id: event["event_id"],
      sender: event["sender"],
      state_key: event["state_key"],
      origin_server_ts: event["origin_server_ts"],
      content: content_from_response(type, event["content"]),
      unsigned: unsigned_from_response(type, event["unsigned"])
    }
  end

  @doc "Normalize the content of a response"
  def content_from_response(type, content) do
    case module_for_type(type) do
      nil -> content
      module -> module.from_response(content)
    end
  end

  def unsigned_from_response(_, nil), do: nil

  def unsigned_from_response(type, unsigned) do
    Map.new(unsigned, fn
      {"age", age} ->
        {:age, age}

      {"transaction_id", transaction_id} ->
        {:transaction_id, transaction_id}

      {"replaces_state", replaces_state} ->
        {:replaces_state, replaces_state}

      {"redacted_by", redacted_by} ->
        {:redacted_by, redacted_by}

      {"redacted_because", redacted_because} ->
        {:redacted_because, from_response(redacted_because)}

      {"prev_content", prev_content} ->
        case module_for_type(type) do
          nil -> {:prev_content, prev_content}
          module -> {:prev_content, module.from_response(prev_content)}
        end

      other ->
        other
    end)
  end

  def module_for_type(type), do: @event_modules[type]

  defimpl Inspect do
    def inspect(event, opts) do
      case Matrx.API.Event.module_for_type(event.type) do
        nil -> "#Event<#{event.type}>"
        _ -> Inspect.Any.inspect(event, opts)
      end
    end
  end
end
