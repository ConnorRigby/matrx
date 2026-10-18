defmodule Matrx.Crypto.OlmMessages do
  @moduledoc """
  Olm encrypted to-device messages (`m.olm.v1.curve25519-aes-sha2`): finding or
  creating the Olm session with a device, then encrypting to it or decrypting
  what it sent us.

  https://spec.matrix.org/v1.19/client-server-api/#molmv1curve25519-aes-sha2
  """

  require Logger
  import Ecto.Query
  alias Matrx.API.Event.RoomEncrypted
  alias Matrx.Crypto.{Device, Devices, Keys}
  alias Matrx.{Olm, Repo, Session}
  alias Matrx.Olm.{InboundSession, OutboundSession}

  @algorithm "m.olm.v1.curve25519-aes-sha2"

  def algorithm, do: @algorithm

  @doc """
  Encrypt `{device, event_type, content}` triples for to-device delivery.

  Missing Olm sessions are created by claiming one-time keys, in a single
  request. Returns `messages` ready for `send_to_device` and the devices we
  could not get a session for.
  """
  @spec encrypt(Session.t(), [{Device.t(), String.t(), map()}], keyword()) ::
          {:ok, %{String.t() => %{String.t() => map()}}, [Device.t()]} | {:error, term()}
  def encrypt(%Session{} = session, events, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)
    devices = events |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(&{&1.user_id, &1.device_id})

    with {:ok, olm_sessions} <- sessions_for(session, devices, api) do
      our_keys = Olm.identity_keys(session.account)

      Enum.reduce_while(events, {:ok, %{}, []}, fn {device, type, content}, {:ok, acc, failed} ->
        case Map.fetch(olm_sessions, device.curve25519) do
          {:ok, olm_session} ->
            case encrypt_one(session, olm_session, our_keys, device, type, content) do
              {:ok, encrypted} ->
                acc =
                  Map.update(
                    acc,
                    device.user_id,
                    %{device.device_id => encrypted},
                    &Map.put(&1, device.device_id, encrypted)
                  )

                {:cont, {:ok, acc, failed}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          :error ->
            {:cont, {:ok, acc, [device | failed]}}
        end
      end)
    end
  end

  defp encrypt_one(session, olm_session, our_keys, device, type, content) do
    payload =
      Jcs.encode(%{
        "type" => type,
        "content" => content,
        "sender" => session.user_id,
        "sender_device" => session.device_id,
        "keys" => %{"ed25519" => our_keys.ed25519},
        "recipient" => device.user_id,
        "recipient_keys" => %{"ed25519" => device.ed25519}
      })

    with {:ok, _olm_session, message_type, body} <- Olm.encrypt(olm_session, payload) do
      {:ok,
       %{
         "algorithm" => @algorithm,
         "sender_key" => our_keys.curve25519,
         "ciphertext" => %{device.curve25519 => %{"type" => message_type, "body" => body}}
       }}
    end
  end

  @doc """
  Decrypt a to-device `m.room.encrypted` event and check it really came from
  the device it claims to. Returns the decrypted event.
  """
  @spec decrypt(Session.t(), %{sender: String.t(), content: term()}, keyword()) ::
          {:ok,
           %{type: String.t(), content: map(), sender: String.t(), sender_device: Device.t()}}
          | {:error, term()}
  def decrypt(session, event, opts \\ [])

  def decrypt(
        %Session{} = session,
        %{sender: sender, content: %RoomEncrypted{algorithm: @algorithm} = content},
        opts
      )
      when is_binary(sender) and is_binary(content.sender_key) and is_map(content.ciphertext) do
    api = Keyword.get(opts, :api, Matrx.API)
    our_keys = Olm.identity_keys(session.account)

    with {:ok, type, body} <- ciphertext_for(content.ciphertext, our_keys.curve25519),
         {:ok, plaintext, created} <- decrypt_body(session, content.sender_key, type, body) do
      result =
        with {:ok, payload} <- parse(plaintext),
             {:ok, device} <- verify(session, sender, content.sender_key, payload, our_keys, api) do
          {:ok,
           %{
             type: payload["type"],
             content: payload["content"],
             sender: sender,
             sender_device: device
           }}
        end

      # A session made for a message that fails verification must not be kept
      with {:error, _} <- result, %{} <- created, do: Repo.delete(created)
      result
    end
  end

  def decrypt(_session, _event, _opts), do: {:error, :unsupported_event}

  defp ciphertext_for(ciphertext, our_key) do
    case Map.get(ciphertext, our_key) do
      %{type: type, body: body} when type in [0, 1] and is_binary(body) -> {:ok, type, body}
      _ -> {:error, :not_for_us}
    end
  end

  defp decrypt_body(session, sender_key, type, body) do
    session
    |> list_sessions(sender_key)
    |> Enum.find_value(fn olm_session ->
      case Olm.decrypt(olm_session, type, body) do
        {:ok, _olm_session, plaintext} -> {:ok, plaintext, nil}
        _ -> nil
      end
    end)
    |> case do
      nil when type == 0 -> create_inbound(session, sender_key, body)
      nil -> {:error, :no_matching_session}
      found -> found
    end
  end

  defp create_inbound(session, sender_key, body) do
    attrs = %{owner_id: session.id, sender_key: sender_key}

    with {:ok, {plaintext, olm_session}} <-
           Olm.create_inbound_session(session.account, sender_key, body, attrs),
         # creating the session consumed a one-time key
         {:ok, _} <- Olm.save_account(session.account) do
      {:ok, plaintext, olm_session}
    end
  end

  defp parse(plaintext) do
    case :json.decode(plaintext) do
      %{"type" => type, "content" => %{}} = payload when is_binary(type) -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  end

  defp verify(session, sender, sender_key, payload, our_keys, api) do
    with :ok <- check(payload["sender"] == sender, :sender_mismatch),
         :ok <- check(payload["recipient"] == session.user_id, :recipient_mismatch),
         :ok <-
           check(
             get_in(payload, ["recipient_keys", "ed25519"]) == our_keys.ed25519,
             :recipient_key_mismatch
           ),
         %Device{} = device <- sender_device(session, sender, sender_key, api),
         :ok <-
           check(get_in(payload, ["keys", "ed25519"]) == device.ed25519, :sender_key_mismatch) do
      {:ok, device}
    else
      nil -> {:error, :unknown_device}
      {:error, _} = error -> error
    end
  end

  defp check(true, _reason), do: :ok
  defp check(_, reason), do: {:error, reason}

  # A device we have not seen yet may be brand new, so ask the server once
  defp sender_device(session, sender, sender_key, api) do
    case Devices.get_by_curve25519(session, sender, sender_key) do
      nil ->
        Devices.track(session, [sender])
        Devices.mark_outdated(session, [sender])
        Devices.refresh(session, api: api)
        Devices.get_by_curve25519(session, sender, sender_key)

      device ->
        device
    end
  end

  # Existing sessions with a device, most recently used first
  defp list_sessions(%Session{id: owner_id}, sender_key) do
    for schema <- [InboundSession, OutboundSession],
        row <-
          Repo.all(
            from(s in schema, where: s.owner_id == ^owner_id and s.sender_key == ^sender_key)
          ) do
      Olm.load_session(row)
    end
    |> Enum.sort_by(& &1.updated_at, {:desc, NaiveDateTime})
  end

  defp sessions_for(session, devices, api) do
    existing =
      for device <- devices,
          [latest | _] <- [list_sessions(session, device.curve25519)],
          into: %{},
          do: {device.curve25519, latest}

    case Enum.reject(devices, &Map.has_key?(existing, &1.curve25519)) do
      [] ->
        {:ok, existing}

      missing ->
        with {:ok, created} <- claim(session, missing, api),
             do: {:ok, Map.merge(existing, created)}
    end
  end

  defp claim(session, devices, api) do
    request =
      Enum.reduce(devices, %{}, fn device, acc ->
        Map.update(
          acc,
          device.user_id,
          %{device.device_id => "signed_curve25519"},
          &Map.put(&1, device.device_id, "signed_curve25519")
        )
      end)

    with {:ok, claimed} <- api.claim_keys(session, %{"one_time_keys" => request}) do
      created =
        for device <- devices,
            {:ok, olm_session} <- [new_outbound(session, device, claimed.one_time_keys)],
            into: %{},
            do: {device.curve25519, olm_session}

      {:ok, created}
    end
  end

  defp new_outbound(session, device, claimed) do
    keys = get_in(claimed, [device.user_id, device.device_id]) || %{}

    with {_id, %{"key" => key}} when is_binary(key) <-
           Enum.find(keys, fn {id, object} ->
             String.starts_with?(id, "signed_curve25519:") and
               Keys.verify_object(object, device.user_id, device.device_id, device.ed25519)
           end),
         {:ok, _} = ok <-
           Olm.create_outbound_session(session.account, device.curve25519, key, %{
             owner_id: session.id,
             sender_key: device.curve25519
           }) do
      ok
    else
      _ ->
        Logger.warning("No usable one-time key for #{device.user_id} #{device.device_id}")
        :error
    end
  end
end
