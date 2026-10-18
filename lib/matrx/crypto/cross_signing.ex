defmodule Matrx.Crypto.CrossSigning do
  @moduledoc """
  Cross-signing for our own user: creating the master, self-signing and
  user-signing keys, signing our device with them, and deciding which of our
  devices are signed by keys we hold.

  Only identities we created ourselves are trusted. Joining a cross-signing
  identity made elsewhere would need SAS verification or secret storage, which
  are not implemented, and other users' keys are never trusted.

  https://spec.matrix.org/v1.19/client-server-api/#cross-signing
  """

  import Ecto.Query
  alias Matrx.Crypto.{CrossSigningKey, Devices, Keys, UIA}
  alias Matrx.{Repo, Session}

  @usages ["master", "self_signing", "user_signing"]

  @doc """
  Create our cross-signing keys, upload them, and sign this device.

  Fails with `:cross_signing_exists` if the account already has cross-signing
  keys (made by another client, or by a previous login of this one), because
  replacing them breaks the verification of everything signed by them. Pass
  `reset: true` to replace them anyway. Servers usually ask for the account
  password when keys are replaced, so pass `password: "..."`.
  """
  @spec bootstrap(Session.t(), keyword()) :: :ok | {:error, term()}
  def bootstrap(%Session{} = session, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    reset? = Keyword.get(opts, :reset, false)

    with :ok <- if(reset?, do: :ok, else: check_not_bootstrapped(session)),
         :ok <- check_server_keys(session, api, reset?) do
      keys = Map.new(@usages, &{&1, generate()})
      body = upload_body(session, keys)

      with :ok <- upload_signing_keys(session, api, body, opts[:password]),
           :ok <- store(session, keys),
           :ok <- sign_own_device(session, api) do
        Devices.track(session, [session.user_id])
        Devices.mark_outdated(session, [session.user_id])
        Devices.refresh(session, api: api)
      end
    end
  end

  @doc "Do we hold cross-signing keys for this login?"
  @spec bootstrapped?(Session.t()) :: boolean()
  def bootstrapped?(session), do: local(session, "master") != nil

  @doc """
  Sign another device of our own with the self-signing key, so that it is
  trusted from now on. Only do this for devices you know to be yours.
  """
  @spec sign_device(Session.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def sign_device(%Session{} = session, device_id, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    with {:ok, response} <- api.keys_query(session, %{"device_keys" => %{session.user_id => []}}),
         %{} = device <- get_in(response.device_keys, [session.user_id, device_id]),
         true <- Devices.verified?(session.user_id, device_id, device),
         {:ok, signed} <- sign(session, "self_signing", device),
         :ok <- upload_signatures(session, api, %{session.user_id => %{device_id => signed}}) do
      Devices.mark_outdated(session, [session.user_id])
      Devices.refresh(session, api: api)
    else
      nil -> {:error, :unknown_device}
      false -> {:error, :invalid_device}
      {:error, _} = error -> error
    end
  end

  @doc """
  Is `device`, as reported by `/keys/query`, signed by our self-signing key,
  which must itself be signed by the master key we hold?
  """
  @spec device_trusted?(Session.t(), String.t(), map(), map()) :: boolean()
  def device_trusted?(%Session{user_id: user_id} = session, user_id, device, response) do
    with %CrossSigningKey{public: master} <- local(session, "master"),
         ^master <- key_of(response.master_keys[user_id], user_id, "master"),
         self_signing when is_binary(self_signing) <-
           key_of(response.self_signing_keys[user_id], user_id, "self_signing"),
         true <- Keys.verify_object(response.self_signing_keys[user_id], user_id, master, master) do
      Keys.verify_object(device, user_id, self_signing, self_signing)
    else
      _ -> false
    end
  end

  def device_trusted?(_session, _user_id, _device, _response), do: false

  defp check_not_bootstrapped(session) do
    if bootstrapped?(session), do: {:error, :already_bootstrapped}, else: :ok
  end

  defp check_server_keys(_session, _api, true), do: :ok

  defp check_server_keys(session, api, false) do
    with {:ok, response} <- api.keys_query(session, %{"device_keys" => %{session.user_id => []}}) do
      if response.master_keys[session.user_id],
        do: {:error, :cross_signing_exists},
        else: :ok
    end
  end

  defp generate do
    {seed, public} = Ed25519.generate_key_pair()
    %{seed: seed, public: Base.encode64(public, padding: false)}
  end

  defp upload_body(session, keys) do
    master = key_object(session, "master", keys["master"])

    for usage <- ["self_signing", "user_signing"], into: %{"master_key" => master} do
      object = key_object(session, usage, keys[usage])
      {"#{usage}_key", sign_with(session, keys["master"], object)}
    end
  end

  defp key_object(session, usage, %{public: public}) do
    %{
      "user_id" => session.user_id,
      "usage" => [usage],
      "keys" => %{"ed25519:#{public}" => public}
    }
  end

  defp upload_signing_keys(session, api, body, password),
    do: UIA.with_password(session, body, password, &api.upload_signing_keys(session, &1))

  defp store(%Session{id: session_id}, keys) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for {usage, %{seed: seed, public: public}} <- keys,
          do: %{
            session_id: session_id,
            usage: usage,
            public: public,
            seed: seed,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(CrossSigningKey, rows,
      on_conflict: {:replace, [:public, :seed, :updated_at]},
      conflict_target: [:session_id, :usage]
    )

    :ok
  end

  defp sign_own_device(session, api) do
    {:ok, signed} = sign(session, "self_signing", Keys.device_keys(session))

    upload_signatures(session, api, %{session.user_id => %{session.device_id => signed}})
  end

  defp upload_signatures(session, api, body) do
    with {:ok, failures} <- api.upload_signatures(session, body) do
      if failures in [nil, %{}], do: :ok, else: {:error, {:signature_failures, failures}}
    end
  end

  defp sign(session, usage, object) do
    case local(session, usage) do
      %CrossSigningKey{} = key -> {:ok, sign_with(session, key, object)}
      nil -> {:error, :not_bootstrapped}
    end
  end

  defp sign_with(session, %{seed: seed, public: public}, object) do
    payload = object |> Map.drop(["signatures", "unsigned"]) |> Jcs.encode()
    signature = payload |> Ed25519.signature(seed) |> Base.encode64(padding: false)
    signatures = %{session.user_id => %{"ed25519:#{public}" => signature}}
    Map.update(object, "signatures", signatures, &Map.merge(&1, signatures))
  end

  defp local(%Session{id: session_id}, usage),
    do:
      Repo.one(
        from(k in CrossSigningKey, where: k.session_id == ^session_id and k.usage == ^usage)
      )

  # The only key of a cross-signing key object, if it is for this user and usage
  defp key_of(%{"user_id" => user_id, "usage" => usage, "keys" => keys}, user_id, wanted)
       when is_list(usage) and is_map(keys) do
    with true <- wanted in usage,
         [{"ed25519:" <> id, key}] when id == key <- Map.to_list(keys) do
      key
    else
      _ -> nil
    end
  end

  defp key_of(_object, _user_id, _usage), do: nil
end
