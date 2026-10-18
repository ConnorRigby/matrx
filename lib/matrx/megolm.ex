defmodule Matrx.Megolm do
  alias Matrx.Repo
  alias Matrx.Megolm.OutboundSession
  alias Matrx.Megolm.InboundSession

  @doc "Create an outbound session. `attrs` (`:owner_id`, `:room_id`, `:sender_key`) are stored with it."
  @spec create_outbound_session(map()) ::
          {:ok, OutboundSession.t()} | {:error, Ecto.Changeset.t()}
  def create_outbound_session(attrs \\ %{}) do
    outbound_session = Vodozemac.create_group_session()
    session_id = Vodozemac.group_session_id(outbound_session)
    session_key = Vodozemac.group_session_key(outbound_session)
    pickle = Vodozemac.pickle_group_session(outbound_session)

    changeset =
      OutboundSession.changeset(
        %OutboundSession{session: outbound_session},
        Map.merge(attrs, %{session_id: session_id, session_key: session_key, pickle: pickle})
      )

    Repo.insert(changeset)
  end

  @doc """
  Create an inbound session from a session key received from another device.
  `attrs` (`:owner_id`, `:room_id`, `:sender_key`) are stored with the session.
  """
  @spec create_inbound_session(String.t(), String.t(), map()) ::
          {:ok, InboundSession.t()} | {:error, Ecto.Changeset.t() | :invalid_session_key}
  def create_inbound_session(session_id, session_key, attrs \\ %{}),
    do: insert_inbound(session_id, session_key, &Vodozemac.create_inbound_group_session/1, attrs)

  @doc """
  Like `create_inbound_session/3`, for an exported key as found in
  `m.forwarded_room_key`. The session can decrypt from the exported index on.
  """
  @spec import_inbound_session(String.t(), String.t(), map()) ::
          {:ok, InboundSession.t()} | {:error, Ecto.Changeset.t() | :invalid_session_key}
  def import_inbound_session(session_id, exported_key, attrs \\ %{}),
    do: insert_inbound(session_id, exported_key, &Vodozemac.import_inbound_group_session/1, attrs)

  # The key comes from another device, so malformed input must not crash us
  defp insert_inbound(session_id, key, build, attrs) do
    with {:ok, inbound_session} <- build.(key),
         ^session_id <- Vodozemac.inbound_group_session_id(inbound_session) do
      pickle = Vodozemac.pickle_inbound_group_session(inbound_session)

      %InboundSession{session: inbound_session}
      |> InboundSession.changeset(
        Map.merge(attrs, %{session_id: session_id, session_key: key, pickle: pickle})
      )
      |> Repo.insert()
    else
      _ -> {:error, :invalid_session_key}
    end
  end

  @spec encrypt(OutboundSession.t(), String.t()) ::
          {:ok, OutboundSession.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def encrypt(%OutboundSession{session: session} = outbound, plaintext) do
    ciphertext = Vodozemac.group_session_encrypt(session, plaintext)
    pickle = Vodozemac.pickle_group_session(session)

    changeset =
      OutboundSession.changeset(outbound, %{
        pickle: pickle,
        message_count: outbound.message_count + 1
      })

    with {:ok, outbound} <- Repo.update(changeset) do
      {:ok, outbound, ciphertext}
    end
  end

  @doc "The key to give a new recipient: it can decrypt from the current message index on"
  @spec current_key(OutboundSession.t()) :: String.t()
  def current_key(%OutboundSession{session: session}), do: Vodozemac.group_session_key(session)

  @doc "Rebuild the NIF session of an outbound session loaded from the database"
  @spec load_outbound(OutboundSession.t()) :: OutboundSession.t()
  def load_outbound(%OutboundSession{session: session} = outbound) when is_reference(session),
    do: outbound

  def load_outbound(%OutboundSession{pickle: pickle} = outbound),
    do: %{outbound | session: Vodozemac.unpickle_group_session(pickle)}

  @doc "Rebuild the NIF session of an inbound session loaded from the database"
  @spec load_inbound(InboundSession.t()) :: InboundSession.t()
  def load_inbound(%InboundSession{session: session} = inbound) when is_reference(session),
    do: inbound

  def load_inbound(%InboundSession{pickle: pickle} = inbound),
    do: %{inbound | session: Vodozemac.unpickle_inbound_group_session(pickle)}

  @spec decrypt(InboundSession.t(), String.t()) ::
          {:ok, InboundSession.t(), String.t()} | {:error, Ecto.Changeset.t() | term()}
  def decrypt(%InboundSession{} = inbound, ciphertext) do
    with {:ok, inbound, plaintext, _index} <- decrypt_message(inbound, ciphertext),
         do: {:ok, inbound, plaintext}
  end

  @doc "Like `decrypt/2`, but also returns the message index"
  @spec decrypt_message(InboundSession.t(), String.t()) ::
          {:ok, InboundSession.t(), String.t(), non_neg_integer()} | {:error, term()}
  def decrypt_message(%InboundSession{session: session} = inbound, ciphertext) do
    with {:ok, %{plaintext: plaintext, message_index: index}} <-
           Vodozemac.decrypt_inbound_group_session_message(session, ciphertext),
         pickle = Vodozemac.pickle_inbound_group_session(session),
         changeset = InboundSession.changeset(inbound, %{pickle: pickle}),
         {:ok, inbound} <- Repo.update(changeset) do
      {:ok, inbound, plaintext, index}
    end
  end
end
