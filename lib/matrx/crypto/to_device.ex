defmodule Matrx.Crypto.ToDevice do
  @moduledoc "Handles to-device events delivered by sync"

  require Logger
  alias Matrx.API.Event
  alias Matrx.API.Event.RoomKey
  alias Matrx.Crypto.{KeyRequests, OlmMessages}
  alias Matrx.{Megolm, Repo, Session}
  alias Matrx.Megolm.InboundSession

  @megolm_algorithm "m.megolm.v1.aes-sha2"

  @spec handle(Session.t(), Event.t(), keyword()) :: :ok | {:error, term()}
  def handle(session, event, opts \\ [])

  def handle(%Session{} = session, %Event{type: "m.room.encrypted"} = event, opts) do
    case OlmMessages.decrypt(session, event, opts) do
      {:ok, decrypted} ->
        result = handle_decrypted(session, decrypted, opts)
        KeyRequests.cancel_fulfilled(session, opts)
        result

      {:error, reason} = error ->
        Logger.warning(
          "Could not decrypt to-device event from #{event.sender}: #{inspect(reason)}"
        )

        error
    end
  end

  def handle(%Session{} = session, %Event{type: "m.room_key_request"} = event, opts) do
    KeyRequests.answer(session, event, opts)
  end

  def handle(_session, %Event{type: type}, _opts) do
    Logger.warning("Unhandled device event: #{type}")
    :ok
  end

  defp handle_decrypted(session, %{type: "m.room_key", content: content} = decrypted, _opts) do
    key = RoomKey.from_response(content)

    if key.algorithm == @megolm_algorithm and
         Enum.all?([key.room_id, key.session_id, key.session_key], &is_binary/1) do
      store_room_key(session, decrypted.sender_device.curve25519, key)
    else
      Logger.warning("Ignoring malformed m.room_key from #{decrypted.sender}")
      {:error, :invalid_room_key}
    end
  end

  defp handle_decrypted(
         session,
         %{type: "m.forwarded_room_key", content: content, sender: sender} = decrypted,
         _opts
       )
       when is_map(content) do
    valid? =
      content["algorithm"] == @megolm_algorithm and sender == session.user_id and
        decrypted.sender_device.device_id != session.device_id and
        Enum.all?(
          [
            content["room_id"],
            content["session_id"],
            content["session_key"],
            content["sender_key"]
          ],
          &is_binary/1
        )

    # Only a key we asked for, in the room we asked about
    request = valid? && KeyRequests.get(session, content["session_id"])

    if request && request.room_id == content["room_id"] do
      store_forwarded_key(session, content)
    else
      Logger.warning("Ignoring unrequested or malformed forwarded room key from #{sender}")
      {:error, :unexpected_forwarded_key}
    end
  end

  defp handle_decrypted(_session, %{type: type, sender: sender}, _opts) do
    Logger.warning("Unhandled encrypted device event #{type} from #{sender}")
    :ok
  end

  defp store_forwarded_key(session, content) do
    if Repo.get_by(InboundSession, session_id: content["session_id"], owner_id: session.id) do
      :ok
    else
      attrs = %{
        owner_id: session.id,
        room_id: content["room_id"],
        sender_key: content["sender_key"]
      }

      with {:ok, _} <-
             Megolm.import_inbound_session(content["session_id"], content["session_key"], attrs),
           do: :ok
    end
  end

  defp store_room_key(session, sender_key, key) do
    # A key we already hold is never replaced, so a resend can't swap it out
    if Repo.get_by(InboundSession, session_id: key.session_id, owner_id: session.id) do
      :ok
    else
      attrs = %{owner_id: session.id, room_id: key.room_id, sender_key: sender_key}

      with {:ok, _} <- Megolm.create_inbound_session(key.session_id, key.session_key, attrs),
           do: :ok
    end
  end
end
