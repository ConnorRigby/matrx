defmodule Matrx.Olm do
  alias Matrx.Repo
  alias Matrx.Olm.Account
  alias Matrx.Olm.OutboundSession
  alias Matrx.Olm.InboundSession

  @doc "Create an Olm account"
  @spec create_account() :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account do
    account_data = Vodozemac.create_account()
    pickle = Vodozemac.pickle(account_data)

    changeset = Account.changeset(%Account{pickle: pickle, account: account_data}, %{})

    with {:ok, account} <- Repo.insert(changeset) do
      {:ok, %{account | account: account_data}}
    end
  end

  @spec identity_keys(Account.t()) :: Vodozemac.identity_keys()
  def identity_keys(%{account: account}) when is_reference(account) do
    Vodozemac.identity_keys(account)
  end

  @spec generate_one_time_keys(Account.t(), pos_integer()) :: Vodozemac.one_time_keys()
  def generate_one_time_keys(%{account: account}, amount) when is_reference(account) do
    Vodozemac.generate_one_time_keys(account, amount)
  end

  @spec mark_keys_as_published(Account.t()) :: :ok
  def mark_keys_as_published(%{account: account}) when is_reference(account) do
    Vodozemac.mark_keys_as_published(account)
  end

  @spec create_outbound_session(Account.t(), Vodozemac.public_key(), Vodozemac.one_time_key()) ::
          {:ok, OutboundSession.t()} | {:error, Ecto.Changeset.t()}
  def create_outbound_session(%{account: account}, public_key, one_time_key) do
    outbound_session = Vodozemac.create_outbound_session(account, public_key, one_time_key)
    pickle = Vodozemac.pickle_session(outbound_session)
    session_id = Vodozemac.session_id(outbound_session)

    OutboundSession.changeset(%OutboundSession{session: outbound_session}, %{
      session_id: session_id,
      pickle: pickle
    })
    |> Repo.insert()
  end

  @spec create_inbound_session(Account.t(), Vodozemac.public_key(), String.t()) ::
          {:ok, {String.t(), InboundSession.t()}} | {:error, Ecto.Changeset.t()}
  def create_inbound_session(%{account: account}, public_key, message) do
    {:ok, {decrypted, inbound_session}} =
      Vodozemac.create_inbound_session(account, public_key, message)

    pickle = Vodozemac.pickle_session(inbound_session)
    session_id = Vodozemac.session_id(inbound_session)

    changeset =
      InboundSession.changeset(%InboundSession{session: inbound_session}, %{
        session_id: session_id,
        pickle: pickle
      })

    with {:ok, inbound_session} = Repo.insert(changeset) do
      {:ok, {decrypted, inbound_session}}
    end
  end

  @spec encrypt(OutboundSession.t() | InboundSession.t(), String.t()) ::
          {:ok, OutboundSession.t() | InboundSession.t(), 0 | 1, String.t()}
          | {:error, Ecto.Changeset.t()}
  def encrypt(%kind{session: session} = outbound_session, message)
      when is_reference(session) and is_binary(message) do
    {type, encrypted} = Vodozemac.encrypt(session, message)
    pickle = Vodozemac.pickle_session(session)
    changeset = kind.changeset(outbound_session, %{pickle: pickle})

    with {:ok, outbound_session} <- Repo.update(changeset) do
      {:ok, outbound_session, type, encrypted}
    end
  end

  @spec decrypt(InboundSession.t() | OutboundSession.t(), 0 | 1, String.t()) ::
          {:ok, InboundSession.t() | OutboundSession.t(), String.t()}
          | {:error, Ecto.Changeset.t() | term}
  def decrypt(%kind{session: session} = inbound_session, type, ciphertext)
      when is_reference(session) and type in [0, 1] and is_binary(ciphertext) do
    with {:ok, plaintext} <- Vodozemac.decrypt(session, type, ciphertext) do
      pickle = Vodozemac.pickle_session(session)
      changeset = kind.changeset(inbound_session, %{pickle: pickle})

      case Repo.update(changeset) do
        {:ok, inbound_session} -> {:ok, inbound_session, plaintext}
        error -> error
      end
    end
  end
end
