defmodule Vodozemac do
  use Rustler, otp_app: :matrx, crate: "vodozemac_nif"

  @type account() :: reference()
  @type session() :: reference()
  @type outbound_group_session() :: reference()
  @type inbound_group_session() :: reference()
  @type identity_keys() :: %{curve25519: String.t(), ed25519: String.t()}
  @type one_time_key() :: String.t()
  @type one_time_keys() :: %{
          created: [one_time_key()],
          removed: [one_time_key()]
        }
  @type public_key() :: String.t()

  ## Acount

  @spec create_account() :: account()
  def create_account(), do: :erlang.nif_error(:nif_not_loaded)

  @spec identity_keys(account) :: identity_keys()
  def identity_keys(_res), do: :erlang.nif_error(:nif_not_loaded)

  @spec generate_one_time_keys(account(), pos_integer()) :: one_time_keys()
  def generate_one_time_keys(_res, _count), do: :erlang.nif_error(:nif_not_loaded)

  @spec one_time_keys(account()) :: [one_time_key()]
  def one_time_keys(_account), do: :erlang.nif_error(:nif_not_loaded)

  @spec mark_keys_as_published(account()) :: :ok
  def mark_keys_as_published(_res), do: :erlang.nif_error(:nif_not_loaded)

  @spec sign(String.t(), String.t()) :: String.t()
  def sign(_res, _message), do: :erlang.nif_error(:nif_not_loaded)

  @spec pickle(account()) :: String.t()
  def pickle(_res), do: :erlang.nif_error(:nif_not_loaded)

  @spec unpickle(account()) :: String.t()
  def unpickle(_pickle), do: :erlang.nif_error(:nif_not_loaded)

  ## OLM

  @spec create_outbound_session(account(), String.t(), String.t()) ::
          {:ok, session()} | {:error, :invalid_message}
  def create_outbound_session(_res, _public_key, _one_time_key),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec create_inbound_session(account(), String.t(), String.t()) ::
          {:ok, {String.t(), session()}} | {:error, term()}
  def create_inbound_session(_res, _public_key, _prev_key_message),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec session_id(session()) :: String.t()
  def session_id(_res), do: :erlang.nif_error(:nif_not_loaded)

  @spec session_keys(session()) :: %{
          identity_key: String.t(),
          base_key: String.t(),
          one_time_key: String.t()
        }
  def session_keys(_res), do: :erlang.nif_error(:nif_not_loaded)

  @spec encrypt(session(), String.t()) :: {0 | 1, String.t()}
  def encrypt(_res, _plaintext), do: :erlang.nif_error(:nif_not_loaded)

  @spec decrypt(session(), 0 | 1, String.t()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(_res, _type, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)

  @spec pickle_session(session()) :: String.t()
  def pickle_session(_res), do: :erlang.nif_error(:nif_not_loaded)

  @spec unpickle_session(String.t()) :: session()
  def unpickle_session(_res), do: :erlang.nif_error(:nif_not_loaded)

  ## MEGOLM

  @spec create_group_session() :: outbound_group_session()
  def create_group_session(), do: :erlang.nif_error(:nif_not_loaded)

  @spec group_session_id(outbound_group_session()) :: String.t()
  def group_session_id(_group_session), do: :erlang.nif_error(:nif_not_loaded)

  @spec group_session_key(outbound_group_session()) :: String.t()
  def group_session_key(_group_session), do: :erlang.nif_error(:nif_not_loaded)

  @spec group_session_encrypt(outbound_group_session(), String.t()) :: String.t()
  def group_session_encrypt(_group_session, _plaintext), do: :erlang.nif_error(:nif_not_loaded)

  @spec pickle_group_session(outbound_group_session()) :: String.t()
  def pickle_group_session(_group_session), do: :erlang.nif_error(:nif_not_loaded)

  @spec unpickle_group_session(String.t()) :: outbound_group_session()
  def unpickle_group_session(_pickle), do: :erlang.nif_error(:nif_not_loaded)

  @spec create_inbound_group_session(String.t()) ::
          {:ok, inbound_group_session()} | {:error, :invalid_message}
  def create_inbound_group_session(_session_key), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Create an inbound session from an exported key, as found in `m.forwarded_room_key`"
  @spec import_inbound_group_session(String.t()) ::
          {:ok, inbound_group_session()} | {:error, :invalid_message}
  def import_inbound_group_session(_exported_key), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Export the session from the first index it can decrypt, as sent in `m.forwarded_room_key`"
  @spec export_inbound_group_session(inbound_group_session()) :: String.t()
  def export_inbound_group_session(_inbound_group_session),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec inbound_group_session_id(inbound_group_session()) :: String.t()
  def inbound_group_session_id(_inbound_group_session), do: :erlang.nif_error(:nif_not_loaded)

  @spec decrypt_inbound_group_session_message(inbound_group_session(), String.t()) ::
          {:ok, %{plaintext: String.t(), message_index: 0 | pos_integer()}} | {:error, term()}
  def decrypt_inbound_group_session_message(_inbound_group_session, _ciphertext),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec pickle_inbound_group_session(inbound_group_session()) :: String.t()
  def pickle_inbound_group_session(_inbound_group_session), do: :erlang.nif_error(:nif_not_loaded)

  @spec unpickle_inbound_group_session(String.t()) :: inbound_group_session()
  def unpickle_inbound_group_session(_pickle), do: :erlang.nif_error(:nif_not_loaded)
end
