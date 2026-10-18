defmodule Matrx.Crypto.Devices do
  @moduledoc """
  Tracks the devices of users we share encrypted rooms with.

  A user is first `track/2`ed (marked outdated). `refresh/2` then runs
  `/keys/query` for every outdated user, verifies each device's self signature,
  and stores the result. `device_lists.changed` from sync marks users outdated
  again; `device_lists.left` untracks them.
  """

  require Logger
  import Ecto.Query
  alias Matrx.Repo
  alias Matrx.Session
  alias Matrx.Crypto.{CrossSigning, Device, TrackedUser}

  @doc "Start tracking users. Already tracked users are left as they are."
  @spec track(Session.t(), [String.t()]) :: :ok
  def track(%Session{id: session_id}, user_ids) do
    now = now()

    rows =
      for user_id <- Enum.uniq(user_ids),
          do: %{
            session_id: session_id,
            user_id: user_id,
            outdated: true,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(TrackedUser, rows, on_conflict: :nothing)
    :ok
  end

  @doc "Stop tracking users and forget their devices"
  @spec untrack(Session.t(), [String.t()]) :: :ok
  def untrack(%Session{id: session_id}, user_ids) do
    Repo.delete_all(
      from(t in TrackedUser, where: t.session_id == ^session_id and t.user_id in ^user_ids)
    )

    Repo.delete_all(
      from(d in Device, where: d.session_id == ^session_id and d.user_id in ^user_ids)
    )

    :ok
  end

  @doc "Flag tracked users (ignoring untracked ones) as needing a `/keys/query`"
  @spec mark_outdated(Session.t(), [String.t()]) :: :ok
  def mark_outdated(%Session{id: session_id}, user_ids) do
    Repo.update_all(
      from(t in TrackedUser, where: t.session_id == ^session_id and t.user_id in ^user_ids),
      set: [outdated: true]
    )

    :ok
  end

  @spec tracked?(Session.t(), String.t()) :: boolean()
  def tracked?(%Session{id: session_id}, user_id) do
    Repo.exists?(
      from(t in TrackedUser, where: t.session_id == ^session_id and t.user_id == ^user_id)
    )
  end

  @spec outdated_users(Session.t()) :: [String.t()]
  def outdated_users(%Session{id: session_id}) do
    Repo.all(
      from(t in TrackedUser, where: t.session_id == ^session_id and t.outdated, select: t.user_id)
    )
  end

  @spec list(Session.t(), String.t()) :: [Device.t()]
  def list(%Session{id: session_id}, user_id) do
    Repo.all(
      from(d in Device,
        where: d.session_id == ^session_id and d.user_id == ^user_id,
        order_by: d.device_id
      )
    )
  end

  @spec get(Session.t(), String.t(), String.t()) :: Device.t() | nil
  def get(%Session{id: session_id}, user_id, device_id) do
    Repo.get_by(Device, session_id: session_id, user_id: user_id, device_id: device_id)
  end

  @doc "Find a device by the curve25519 key it uses to send Olm messages"
  @spec get_by_curve25519(Session.t(), String.t()) :: Device.t() | nil
  def get_by_curve25519(%Session{id: session_id}, curve25519) do
    Repo.one(
      from(d in Device,
        where: d.session_id == ^session_id and d.curve25519 == ^curve25519,
        limit: 1
      )
    )
  end

  @doc "Like `get_by_curve25519/2`, but only for a given user's devices"
  @spec get_by_curve25519(Session.t(), String.t(), String.t()) :: Device.t() | nil
  def get_by_curve25519(%Session{id: session_id}, user_id, curve25519) do
    Repo.one(
      from(d in Device,
        where:
          d.session_id == ^session_id and d.user_id == ^user_id and d.curve25519 == ^curve25519,
        limit: 1
      )
    )
  end

  @doc "Query the server for every outdated user and store their verified devices"
  @spec refresh(Session.t(), keyword()) :: :ok | {:error, term()}
  def refresh(%Session{} = session, opts \\ []) do
    api = Keyword.get(opts, :api, Matrx.API)

    case outdated_users(session) do
      [] ->
        :ok

      users ->
        query = %{"device_keys" => Map.new(users, &{&1, []})}

        with {:ok, response} <- api.keys_query(session, query) do
          failed = failed_servers(response)

          {fresh, retry} =
            Enum.split_with(users, fn user -> server_name(user) not in failed end)

          Enum.each(fresh, &store_user(session, &1, response.device_keys[&1] || %{}, response))
          if retry != [], do: Logger.warning("keys/query failed for #{inspect(retry)}")
          :ok
        end
    end
  end

  defp store_user(%Session{id: session_id} = session, user_id, reported, response) do
    valid =
      for {device_id, device} <- reported,
          verified?(user_id, device_id, device),
          not key_changed?(session, user_id, device_id, device),
          do: {device_id, device}

    reported_ids = Map.keys(reported)

    Repo.transaction(fn ->
      Enum.each(valid, fn {device_id, device} ->
        upsert(
          session_id,
          user_id,
          device_id,
          device,
          CrossSigning.device_trusted?(session, user_id, device, response)
        )
      end)

      Repo.delete_all(
        from(d in Device,
          where:
            d.session_id == ^session_id and d.user_id == ^user_id and
              d.device_id not in ^reported_ids
        )
      )

      Repo.update_all(
        from(t in TrackedUser, where: t.session_id == ^session_id and t.user_id == ^user_id),
        set: [outdated: false]
      )
    end)
  end

  defp upsert(session_id, user_id, device_id, device, trusted) do
    now = now()

    Repo.insert_all(
      Device,
      [
        %{
          session_id: session_id,
          user_id: user_id,
          device_id: device_id,
          curve25519: device["keys"]["curve25519:#{device_id}"],
          ed25519: device["keys"]["ed25519:#{device_id}"],
          algorithms: device["algorithms"] || [],
          display_name: get_in(device, ["unsigned", "device_display_name"]),
          trusted: trusted,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict:
        {:replace, [:curve25519, :ed25519, :algorithms, :display_name, :trusted, :updated_at]},
      conflict_target: [:session_id, :user_id, :device_id]
    )
  end

  # A device id must keep its signing key; a changed key is a possible impersonation.
  defp key_changed?(session, user_id, device_id, device) do
    new_key = device["keys"]["ed25519:#{device_id}"]

    case get(session, user_id, device_id) do
      %Device{ed25519: old} when old != new_key ->
        Logger.warning("Ignoring #{user_id} #{device_id}: ed25519 key changed")
        true

      _ ->
        false
    end
  end

  @doc "Is this device signed by our own cross-signing keys?"
  @spec trusted?(Session.t(), String.t(), String.t()) :: boolean()
  def trusted?(session, user_id, device_id) do
    match?(%Device{trusted: true}, get(session, user_id, device_id))
  end

  @doc false
  @spec verified?(String.t(), String.t(), map()) :: boolean()
  def verified?(user_id, device_id, %{"user_id" => user_id, "device_id" => device_id} = device) do
    with ed when is_binary(ed) <- device["keys"]["ed25519:#{device_id}"],
         true <- is_binary(device["keys"]["curve25519:#{device_id}"]) do
      Matrx.Crypto.Keys.verify_object(device, user_id, device_id, ed)
    else
      _ -> false
    end
  end

  def verified?(_user_id, _device_id, _device), do: false

  defp failed_servers(%{failures: failures}) when is_map(failures), do: Map.keys(failures)
  defp failed_servers(_), do: []

  defp server_name(user_id), do: user_id |> String.split(":", parts: 2) |> List.last()

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
