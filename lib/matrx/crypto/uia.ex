defmodule Matrx.Crypto.UIA do
  @moduledoc """
  User-interactive authentication with the account password, for endpoints
  that ask for it (replacing cross-signing keys, deleting devices).

  https://spec.matrix.org/v1.19/client-server-api/#password-based
  """

  @doc """
  Call `fun.(body)`. If the server answers with `{:error, {:uia_required, session}}`
  the call is repeated with password auth, or fails with `:password_required`.
  """
  @spec with_password(Matrx.Session.t(), map(), String.t() | nil, (map() -> term())) :: term()
  def with_password(session, body, password, fun) do
    case fun.(body) do
      {:error, {:uia_required, uia_session}} when is_binary(password) ->
        auth = %{
          "type" => "m.login.password",
          "identifier" => %{"type" => "m.id.user", "user" => session.user_id},
          "password" => password,
          "session" => uia_session
        }

        fun.(Map.put(body, "auth", auth))

      {:error, {:uia_required, _}} ->
        {:error, :password_required}

      other ->
        other
    end
  end
end
