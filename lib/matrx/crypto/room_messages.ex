defmodule Matrx.Crypto.RoomMessages do
  @moduledoc "Decrypts `m.room.encrypted` timeline events (`m.megolm.v1.aes-sha2`)"

  alias Matrx.API.Event
  alias Matrx.API.Event.RoomEncrypted
  alias Matrx.Crypto.Devices
  alias Matrx.Megolm
  alias Matrx.Megolm.{InboundSession, MessageIndex}
  alias Matrx.{Repo, Session}

  @algorithm "m.megolm.v1.aes-sha2"

  @type error ::
          :unsupported_event
          | :unknown_session
          | :sender_key_mismatch
          | :unknown_device
          | :room_mismatch
          | :replayed
          | :invalid_payload
          | {:decrypt_failed, term()}

  def algorithm, do: @algorithm

  @doc "Whether `event` is an encrypted event this module can attempt to decrypt"
  @spec encrypted?(Event.t()) :: boolean()
  def encrypted?(%Event{
        type: "m.room.encrypted",
        content: %RoomEncrypted{algorithm: @algorithm}
      }),
      do: true

  def encrypted?(_event), do: false

  @doc """
  Decrypt a room event, returning the event as it was before encryption, with
  the envelope's `event_id`, `sender`, timestamp and `unsigned` kept.
  """
  @spec decrypt(Session.t(), String.t(), Event.t()) :: {:ok, Event.t()} | {:error, error()}
  def decrypt(%Session{} = session, room_id, %Event{} = event) do
    if encrypted?(event) do
      content = event.content

      with {:ok, inbound} <- find_session(session, content),
           :ok <- check_sender(session, event, content, inbound),
           :ok <- check_room(inbound, room_id),
           {:ok, plaintext, index} <- decrypt_ciphertext(inbound, content.ciphertext),
           {:ok, payload} <- parse_payload(plaintext, room_id),
           :ok <- check_replay(inbound, index, event) do
        {:ok, rebuild(event, payload)}
      end
    else
      {:error, :unsupported_event}
    end
  end

  defp find_session(_session, %{session_id: id}) when not is_binary(id),
    do: {:error, :unknown_session}

  defp find_session(session, %{session_id: id}) do
    case Repo.get_by(InboundSession, session_id: id, owner_id: session.id) do
      nil -> {:error, :unknown_session}
      inbound -> {:ok, Megolm.load_inbound(inbound)}
    end
  end

  # The key must have come from the device that the event claims, and that
  # device must belong to the event's sender.
  defp check_sender(session, event, content, inbound) do
    cond do
      inbound.sender_key != content.sender_key ->
        {:error, :sender_key_mismatch}

      is_nil(Devices.get_by_curve25519(session, event.sender, inbound.sender_key)) ->
        {:error, :unknown_device}

      true ->
        :ok
    end
  end

  defp check_room(%{room_id: room_id}, room_id), do: :ok
  defp check_room(_inbound, _room_id), do: {:error, :room_mismatch}

  defp decrypt_ciphertext(_inbound, ciphertext) when not is_binary(ciphertext),
    do: {:error, {:decrypt_failed, :invalid_message}}

  defp decrypt_ciphertext(inbound, ciphertext) do
    case Megolm.decrypt_message(inbound, ciphertext) do
      {:ok, _inbound, plaintext, index} -> {:ok, plaintext, index}
      {:error, reason} -> {:error, {:decrypt_failed, reason}}
    end
  end

  defp parse_payload(plaintext, room_id) do
    case Jason.decode(plaintext) do
      {:ok, %{"type" => type, "content" => %{}, "room_id" => ^room_id} = payload}
      when is_binary(type) ->
        {:ok, payload}

      {:ok, %{"room_id" => other}} when other != room_id ->
        {:error, :room_mismatch}

      _ ->
        {:error, :invalid_payload}
    end
  end

  # An index may be decrypted again for the same event, but never for another one
  defp check_replay(inbound, index, event) do
    key = [session_id: inbound.session_id, message_index: index]

    case Repo.get_by(MessageIndex, key) do
      nil ->
        Repo.insert!(%MessageIndex{
          session_id: inbound.session_id,
          message_index: index,
          event_id: event.event_id,
          origin_server_ts: event.origin_server_ts
        })

        :ok

      %{event_id: id, origin_server_ts: ts} ->
        if id == event.event_id and ts == event.origin_server_ts,
          do: :ok,
          else: {:error, :replayed}
    end
  end

  defp rebuild(event, payload) do
    decrypted =
      Event.from_response(%{
        "type" => payload["type"],
        "content" => payload["content"],
        "event_id" => event.event_id,
        "sender" => event.sender,
        "origin_server_ts" => event.origin_server_ts
      })

    %{decrypted | unsigned: event.unsigned}
  end
end
