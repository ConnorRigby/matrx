defmodule Matrx.Crypto.Keys do
  @moduledoc """
  Builds and uploads this device's identity and one-time keys.

  https://spec.matrix.org/v1.19/client-server-api/#post_matrixclientv3keysupload
  """

  alias Matrx.Olm
  alias Matrx.Session

  @olm_algorithm "m.olm.v1.curve25519-aes-sha2"
  @megolm_algorithm "m.megolm.v1.aes-sha2"

  # Keep the server stocked up to `@target` keys, refilling once below `@low_water`.
  @target 50
  @low_water 25

  @doc "The signed `device_keys` object for this session"
  @spec device_keys(Session.t()) :: map()
  def device_keys(%Session{account: account} = session) do
    keys = Olm.identity_keys(account)

    unsigned = %{
      "user_id" => session.user_id,
      "device_id" => session.device_id,
      "algorithms" => [@olm_algorithm, @megolm_algorithm],
      "keys" => %{
        "curve25519:#{session.device_id}" => keys.curve25519,
        "ed25519:#{session.device_id}" => keys.ed25519
      }
    }

    sign_object(session, unsigned)
  end

  @doc "Unpublished one-time keys as `signed_curve25519:<id>` objects"
  @spec signed_one_time_keys(Session.t()) :: map()
  def signed_one_time_keys(%Session{account: %{account: ref}} = session) do
    ref
    |> Vodozemac.one_time_keys()
    |> Map.new(fn {key_id, key} ->
      {"signed_curve25519:#{key_id}", sign_object(session, %{"key" => key})}
    end)
  end

  @doc """
  Sign `object` as this device. Any existing `signatures`/`unsigned` fields are
  excluded from the signed bytes, as the spec requires, and the result carries
  the new signature.
  """
  @spec sign_object(Session.t(), map()) :: map()
  def sign_object(%Session{account: %{account: ref}} = session, object) do
    payload = Map.drop(object, ["signatures", "unsigned"])
    signature = Vodozemac.sign(ref, Jcs.encode(payload))
    signatures = %{session.user_id => %{"ed25519:#{session.device_id}" => signature}}
    Map.update(object, "signatures", signatures, &Map.merge(&1, signatures))
  end

  @doc """
  Check that `object` carries a valid signature by the given device, using its
  ed25519 key. `signatures` and `unsigned` are excluded from the signed bytes.
  """
  @spec verify_object(map(), String.t(), String.t(), String.t()) :: boolean()
  def verify_object(object, user_id, device_id, ed25519_key) when is_map(object) do
    with sig when is_binary(sig) <-
           get_in(object, ["signatures", user_id, "ed25519:#{device_id}"]),
         {:ok, sig} <- Base.decode64(sig, padding: false),
         {:ok, key} <- Base.decode64(ed25519_key, padding: false),
         32 <- byte_size(key) do
      payload = object |> Map.drop(["signatures", "unsigned"]) |> Jcs.encode()
      Ed25519.valid_signature?(sig, payload, key)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def verify_object(_object, _user_id, _device_id, _key), do: false

  @doc """
  Upload device keys plus enough fresh one-time keys to reach the target.
  Returns the new server side one-time key count.
  """
  @spec upload(Session.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def upload(%Session{} = session, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)
    on_server = Keyword.get(opts, :on_server, 0)
    publish(session, api, on_server, true)
  end

  @doc """
  Upload more one-time keys if the server's `signed_curve25519` count is low.
  Returns `:ok` when nothing needed uploading.
  """
  @spec maybe_replenish(Session.t(), non_neg_integer(), keyword()) ::
          :ok | {:ok, non_neg_integer()} | {:error, term()}
  def maybe_replenish(%Session{} = session, on_server, opts \\ []) do
    if on_server < @low_water do
      publish(session, Keyword.get(opts, :api, Matrx.API), on_server, false)
    else
      :ok
    end
  end

  defp publish(session, api, on_server, include_device_keys?) do
    unpublished = map_size(Vodozemac.one_time_keys(session.account.account))
    missing = max(@target - on_server - unpublished, 0)

    if missing > 0, do: Olm.generate_one_time_keys(session.account, missing)

    body = %{"one_time_keys" => signed_one_time_keys(session)}

    body =
      if include_device_keys?, do: Map.put(body, "device_keys", device_keys(session)), else: body

    with {:ok, response} <- api.upload_keys(session, body),
         :ok <- Olm.mark_keys_as_published(session.account),
         {:ok, _} <- Olm.save_account(session.account) do
      {:ok, response.one_time_key_counts.signed_curve25519}
    end
  end
end
