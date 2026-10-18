defmodule Matrx.Megolm do
  alias Matrx.Repo
  alias Matrx.Megolm.OutboundSession
  alias Matrx.Megolm.InboundSession

  @spec create_outbound_session() :: {:ok, OutboundSession.t()} | {:error, Ecto.Changeset.t()}
  def create_outbound_session() do
    outbound_session = Vodozemac.create_group_session()
    session_id = Vodozemac.group_session_id(outbound_session)
    session_key = Vodozemac.group_session_key(outbound_session)
    pickle = Vodozemac.pickle_group_session(outbound_session)

    changeset =
      OutboundSession.changeset(%OutboundSession{session: outbound_session}, %{
        session_id: session_id,
        session_key: session_key,
        pickle: pickle
      })

    Repo.insert(changeset)
  end

  @spec create_inbound_session(String.t(), String.t()) ::
          {:ok, InboundSession.t()} | {:error, Ecto.Changeset.t()}
  def create_inbound_session(session_id, session_key) do
    inbound_session = Vodozemac.create_inbound_group_session(session_key)
    ^session_id = Vodozemac.inbound_group_session_id(inbound_session)
    ^session_id = Vodozemac.inbound_group_session_id(inbound_session)
    pickle = Vodozemac.pickle_inbound_group_session(inbound_session)

    changeset =
      InboundSession.changeset(%InboundSession{session: inbound_session}, %{
        session_id: session_id,
        session_key: session_key,
        pickle: pickle
      })

    Repo.insert(changeset)
  end

  @spec encrypt(OutboundSession.t(), String.t()) ::
          {:ok, OutboundSession.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def encrypt(%OutboundSession{session: session} = outbound, plaintext) do
    ciphertext = Vodozemac.group_session_encrypt(session, plaintext)
    pickle = Vodozemac.pickle_group_session(session)
    changeset = OutboundSession.changeset(outbound, %{pickle: pickle})

    with {:ok, outbound} <- Repo.update(changeset) do
      {:ok, outbound, ciphertext}
    end
  end

  @spec decrypt(OutboundSession.t(), String.t()) ::
          {:ok, InboundSession.t(), String.t()} | {:error, Ecto.Changeset.t() | term()}
  def decrypt(%InboundSession{session: session} = inbound, ciphertext) do
    with {:ok, %{plaintext: plaintext, message_index: _}} <-
           Vodozemac.decrypt_inbound_group_session_message(session, ciphertext),
         pickle = Vodozemac.pickle_inbound_group_session(session),
         changeset = InboundSession.changeset(inbound, %{pickle: pickle}),
         {:ok, inbound} <- Repo.update(changeset) do
      {:ok, inbound, plaintext}
    end
  end
end
