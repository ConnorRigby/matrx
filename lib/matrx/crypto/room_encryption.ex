defmodule Matrx.Crypto.RoomEncryption do
  @moduledoc """
  Sends encrypted events to a room (`m.megolm.v1.aes-sha2`).

  Each room has an outbound Megolm session per logged in device. Its key is
  sent, Olm encrypted, to every device of every member before it is used, and
  the session is replaced when it is old, has encrypted enough messages, or
  when a device it was shared with is no longer a recipient.

  Sends for one room must not run concurrently, or two sessions may be created:
  use `Matrx.Room.send_event/5`, which serialises them.
  """

  require Logger
  import Ecto.Query
  alias Matrx.Crypto.{Device, Devices, OlmMessages, RoomMessages}
  alias Matrx.Megolm.{OutboundSession, Share}
  alias Matrx.{Megolm, Olm, Repo, Room, Session}

  @default_rotation_msgs 100
  @default_rotation_ms :timer.hours(24) * 7

  @doc """
  Encrypt and send an event to a room.

  Options: `:api`, and `:room` (the result of `Room.encryption_info/1`, which is
  looked up by default).
  """
  @spec send_event(Session.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, %{event_id: String.t()}} | {:error, term()}
  def send_event(%Session{} = session, room_id, type, content, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    with {:ok, room} <- room_info(room_id, opts),
         {:ok, encrypted} <- encrypt(session, room_id, room, type, content, api) do
      api.send_room_message(session, room_id, transaction_id(), "m.room.encrypted", encrypted)
    end
  end

  defp room_info(room_id, opts) do
    case Keyword.fetch(opts, :room) do
      {:ok, room} ->
        {:ok, room}

      :error ->
        with :error <- Room.encryption_info(room_id), do: {:error, :room_not_encrypted}
    end
  end

  defp encrypt(session, room_id, %{encryption: encryption} = room, type, content, api) do
    with :ok <- check_algorithm(encryption) do
      refresh_devices(session, room.members, api)
      recipients = recipient_devices(session, room.members)

      with {:ok, outbound} <- current_session(session, room_id, encryption, recipients),
           :ok <- share_key(session, outbound, room_id, recipients, api),
           plaintext =
             Jason.encode!(%{"type" => type, "content" => content, "room_id" => room_id}),
           {:ok, _outbound, ciphertext} <- Megolm.encrypt(outbound, plaintext) do
        {:ok,
         %{
           "algorithm" => RoomMessages.algorithm(),
           "sender_key" => Olm.identity_keys(session.account).curve25519,
           "device_id" => session.device_id,
           "session_id" => outbound.session_id,
           "ciphertext" => ciphertext
         }}
      end
    end
  end

  defp check_algorithm(%{algorithm: algorithm}) do
    if algorithm == RoomMessages.algorithm(), do: :ok, else: {:error, :unsupported_algorithm}
  end

  # Members we don't know the devices of yet, or whose devices changed, are queried first
  defp refresh_devices(session, members, api) do
    :ok = Devices.track(session, members)

    with {:error, reason} <- Devices.refresh(session, api: api) do
      Logger.warning("Could not refresh devices before sending: #{inspect(reason)}")
    end
  end

  # Every device of every member except this one
  defp recipient_devices(session, members) do
    members
    |> Enum.uniq()
    |> Enum.flat_map(&Devices.list(session, &1))
    |> Enum.reject(&(&1.user_id == session.user_id and &1.device_id == session.device_id))
  end

  defp current_session(session, room_id, encryption, recipients) do
    query =
      from(o in OutboundSession,
        where: o.owner_id == ^session.id and o.room_id == ^room_id,
        order_by: [desc: o.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        create_session(session, room_id)

      outbound ->
        if rotate?(outbound, encryption, recipients) do
          Repo.delete(outbound)
          create_session(session, room_id)
        else
          {:ok, Megolm.load_outbound(outbound)}
        end
    end
  end

  defp rotate?(outbound, encryption, recipients) do
    max_messages = encryption.rotation_period_msgs || @default_rotation_msgs
    max_age = encryption.rotation_period_ms || @default_rotation_ms

    age =
      DateTime.diff(
        DateTime.utc_now(),
        DateTime.from_naive!(outbound.inserted_at, "Etc/UTC"),
        :millisecond
      )

    wanted = MapSet.new(recipients, &{&1.user_id, &1.device_id})

    shared_with_unwanted? =
      Repo.all(from(s in Share, where: s.session_id == ^outbound.session_id))
      |> Enum.any?(&(not MapSet.member?(wanted, {&1.user_id, &1.device_id})))

    outbound.message_count >= max_messages or age >= max_age or shared_with_unwanted?
  end

  defp create_session(session, room_id) do
    sender_key = Olm.identity_keys(session.account).curve25519
    attrs = %{owner_id: session.id, room_id: room_id, sender_key: sender_key}

    with {:ok, outbound} <- Megolm.create_outbound_session(attrs),
         # we need to read our own events when the server echoes them back
         {:ok, _inbound} <-
           Megolm.create_inbound_session(outbound.session_id, outbound.session_key, attrs) do
      {:ok, outbound}
    end
  end

  defp share_key(session, outbound, room_id, recipients, api) do
    shared =
      from(s in Share,
        where: s.session_id == ^outbound.session_id,
        select: {s.user_id, s.device_id}
      )
      |> Repo.all()
      |> MapSet.new()

    case Enum.reject(recipients, &MapSet.member?(shared, {&1.user_id, &1.device_id})) do
      [] ->
        :ok

      devices ->
        content = %{
          "algorithm" => RoomMessages.algorithm(),
          "room_id" => room_id,
          "session_id" => outbound.session_id,
          "session_key" => Megolm.current_key(outbound)
        }

        send_key(session, outbound, devices, content, api)
    end
  end

  defp send_key(session, outbound, devices, content, api) do
    events = Enum.map(devices, &{&1, "m.room_key", content})

    with {:ok, messages, failed} <- OlmMessages.encrypt(session, events, api: api) do
      for %Device{} = device <- failed do
        Logger.warning("Could not share a room key with #{device.user_id} #{device.device_id}")
      end

      if messages != %{} do
        with {:ok, _} <- api.send_to_device(session, transaction_id(), %{"messages" => messages}) do
          record_shares(outbound, devices -- failed)
        end
      else
        :ok
      end
    end
  end

  defp record_shares(outbound, devices) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for d <- devices,
          do: %{
            session_id: outbound.session_id,
            user_id: d.user_id,
            device_id: d.device_id,
            inserted_at: now
          }

    Repo.insert_all(Share, rows, on_conflict: :nothing)
    :ok
  end

  @doc false
  def transaction_id do
    # the server remembers ids per access token, so they must not repeat across restarts
    "matrx#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end
end
