defmodule Matrx.APIError do
  defstruct [:errcode, :error]

  @type errcode ::
          :m_forbidden
          | :m_unrecognized
          | :m_not_json
          | :m_unknown
          | :m_invalid_param
          | :m_invalid_signature
          | :m_user_in_use
          | :m_invalid_username
          | :m_unknown_token
  @type t :: %__MODULE__{errcode: errcode, error: String.t()}

  def from_json(%{"errcode" => "M_FORBIDDEN", "error" => error}) do
    %__MODULE__{errcode: :m_forbidden, error: error}
  end

  def from_json(%{"errcode" => "M_UNRECOGNIZED", "error" => error}) do
    %__MODULE__{errcode: :m_unrecognized, error: error}
  end

  def from_json(%{"errcode" => "M_NOT_JSON", "error" => error}) do
    %__MODULE__{errcode: :m_not_json, error: error}
  end

  def from_json(%{"errcode" => "M_UNKNOWN", "error" => error}) do
    %__MODULE__{errcode: :m_unknown, error: error}
  end

  def from_json(%{"errcode" => "M_INVALID_PARAM", "error" => error}) do
    %__MODULE__{errcode: :m_invalid_param, error: error}
  end

  def from_json(%{"errcode" => "M_INVALID_SIGNATURE", "error" => error}) do
    %__MODULE__{errcode: :m_invalid_signature, error: error}
  end

  def from_json(%{"errcode" => "M_USER_IN_USE", "error" => error}) do
    %__MODULE__{errcode: :m_user_in_use, error: error}
  end

  def from_json(%{"errcode" => "M_INVALID_USERNAME", "error" => error}) do
    %__MODULE__{errcode: :m_invalid_username, error: error}
  end

  def from_json(%{"errcode" => "M_UNKNOWN_TOKEN", "error" => error}) do
    %__MODULE__{errcode: :m_unknown_token, error: error}
  end
end
