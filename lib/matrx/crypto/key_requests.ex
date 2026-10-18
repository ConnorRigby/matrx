defmodule Matrx.Crypto.KeyRequests do
  @moduledoc """
  Asking our other devices for room keys we are missing (`m.room_key_request`),
  and cancelling once we have them.

  Requests only go to our own user, and a `m.forwarded_room_key` is only
  accepted for a key we asked for, from one of our own devices. Requests from
  our other devices are answered only if the device is trusted, see
  `Matrx.Crypto.CrossSigning`.

  https://spec.matrix.org/v1.19/client-server-api/#key-requests
  """

  require Logger
  import Ecto.Query
  alias Matrx.Crypto.{Device, Devices, OlmMessages}
  alias Matrx.{Megolm, Olm, Repo, Session}
  alias Matrx.Megolm.{InboundSession, KeyRequest}

  @algorithm "m.megolm.v1.aes-sha2"

  @doc """
  Request the keys for undecryptable events, `{room_id, event}` pairs. A key is
  only requested once.
  """
  @spec request(Session.t(), [{String.t(), map()}], keyword()) :: :ok
  def request(%Session{} = session, events, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    events
    |> Enum.flat_map(fn {room_id, event} ->
      case event.content do
        %{session_id: sid, sender_key: key} when is_binary(sid) and is_binary(key) ->
          [{room_id, sid, key}]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.reject(fn {_room, sid, _key} -> requested?(session, sid) or known?(session, sid) end)
    |> Enum.each(&send_request(session, &1, api))
  end

  @doc "Cancel requests for keys that have arrived since"
  @spec cancel_fulfilled(Session.t(), keyword()) :: :ok
  def cancel_fulfilled(%Session{id: owner_id} = session, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    for %KeyRequest{} = request <- Repo.all(from(r in KeyRequest, where: r.owner_id == ^owner_id)),
        known?(session, request.session_id) do
      send_to_own_devices(session, api, %{
        "action" => "request_cancellation",
        "request_id" => request.id,
        "requesting_device_id" => session.device_id
      })

      Repo.delete(request)
    end

    :ok
  end

  @doc """
  Answer an `m.room_key_request` from another device of ours by forwarding the
  key (`m.forwarded_room_key`). Only devices signed by our own cross-signing
  keys are answered, and only for keys we hold for that room and sender.
  """
  @spec answer(Session.t(), %{sender: String.t(), content: term()}, keyword()) ::
          :ok | {:error, term()}
  def answer(session, event, opts \\ [])

  def answer(
        %Session{} = session,
        %{
          sender: sender,
          content: %{
            "action" => "request",
            "requesting_device_id" => device_id,
            "body" => %{"algorithm" => @algorithm} = body
          }
        },
        opts
      )
      when sender == session.user_id and is_binary(device_id) and
             device_id != session.device_id do
    api = Keyword.get(opts, :api, Matrx.API)

    with %Device{trusted: true} = device <- requesting_device(session, device_id, api),
         %InboundSession{} = inbound <- find_key(session, body),
         {:ok, content} <- forward_content(session, inbound),
         {:ok, messages, []} <-
           OlmMessages.encrypt(session, [{device, "m.forwarded_room_key", content}], opts),
         {:ok, _} <- api.send_to_device(session, transaction_id(), %{"messages" => messages}) do
      :ok
    else
      %Device{} ->
        Logger.warning("Not sharing a room key with the untrusted device #{device_id}")
        {:error, :untrusted_device}

      nil ->
        {:error, :unknown_key_or_device}

      {:ok, _, [_ | _]} ->
        {:error, :no_olm_session}

      {:error, _} = error ->
        error
    end
  end

  def answer(_session, _event, _opts), do: :ok

  # A device we have not seen yet may be brand new, so ask the server once
  defp requesting_device(session, device_id, api) do
    case Devices.get(session, session.user_id, device_id) do
      %Device{trusted: true} = device -> device
      # unknown, or maybe signed since we last looked
      _ -> refresh_and_get(session, device_id, api)
    end
  end

  defp refresh_and_get(session, device_id, api) do
    Devices.track(session, [session.user_id])
    Devices.mark_outdated(session, [session.user_id])
    Devices.refresh(session, api: api)
    Devices.get(session, session.user_id, device_id)
  end

  defp find_key(session, %{"session_id" => session_id, "room_id" => room_id, "sender_key" => key}) do
    case Repo.get_by(InboundSession, owner_id: session.id, session_id: session_id) do
      %InboundSession{room_id: ^room_id, sender_key: ^key} = inbound -> inbound
      _ -> nil
    end
  end

  defp find_key(_session, _body), do: nil

  defp forward_content(session, inbound) do
    our_keys = Olm.identity_keys(session.account)

    claimed =
      if inbound.sender_key == our_keys.curve25519 do
        our_keys.ed25519
      else
        case Devices.get_by_curve25519(session, inbound.sender_key) do
          %Device{ed25519: ed25519} -> ed25519
          nil -> nil
        end
      end

    if claimed do
      exported =
        inbound
        |> Megolm.load_inbound()
        |> Map.fetch!(:session)
        |> Vodozemac.export_inbound_group_session()

      {:ok,
       %{
         "algorithm" => @algorithm,
         "room_id" => inbound.room_id,
         "sender_key" => inbound.sender_key,
         "session_id" => inbound.session_id,
         "session_key" => exported,
         "sender_claimed_ed25519_key" => claimed,
         "forwarding_curve25519_key_chain" => []
       }}
    else
      {:error, :unknown_sender_device}
    end
  end

  @doc "The outstanding request for a key, if we asked for it"
  @spec get(Session.t(), String.t()) :: KeyRequest.t() | nil
  def get(%Session{id: owner_id}, session_id),
    do: Repo.get_by(KeyRequest, owner_id: owner_id, session_id: session_id)

  defp requested?(session, session_id), do: get(session, session_id) != nil

  defp known?(%Session{id: owner_id}, session_id),
    do:
      Repo.exists?(
        from(s in InboundSession, where: s.owner_id == ^owner_id and s.session_id == ^session_id)
      )

  defp send_request(session, {room_id, session_id, sender_key}, api) do
    {:ok, request} =
      Repo.insert(%KeyRequest{
        owner_id: session.id,
        room_id: room_id,
        session_id: session_id,
        sender_key: sender_key
      })

    result =
      send_to_own_devices(session, api, %{
        "action" => "request",
        "request_id" => request.id,
        "requesting_device_id" => session.device_id,
        "body" => %{
          "algorithm" => @algorithm,
          "room_id" => room_id,
          "sender_key" => sender_key,
          "session_id" => session_id
        }
      })

    # Not recorded when it never went out, so it is tried again next time
    with {:error, reason} <- result do
      Logger.warning("Could not request room key #{session_id}: #{inspect(reason)}")
      Repo.delete(request)
    end
  end

  defp send_to_own_devices(session, api, content) do
    messages = %{session.user_id => %{"*" => content}}

    with {:ok, _} <-
           api.send_to_device(session, transaction_id(), %{
             "type" => "m.room_key_request",
             "messages" => messages
           }),
         do: :ok
  end

  defp transaction_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
