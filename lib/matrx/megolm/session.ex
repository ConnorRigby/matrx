defmodule Matrx.Megolm.Session do
  @moduledoc """
  Helper macro module to represent inbound and outbound session.

  Options: `:table`; `counted: true` for outbound sessions, which keep the
  number of messages they encrypted so they can be rotated; and `inbound: true`,
  which makes the key an `id` so that every logged in device can hold a copy of
  the same session (outbound sessions are only ever created by us).
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)
    counted? = Keyword.get(opts, :counted, false)
    inbound? = Keyword.get(opts, :inbound, false)

    quote location: :keep do
      use Ecto.Schema
      import Ecto.Changeset

      @derive {Inspect, [except: [:pickle, :pickle_data]]}

      @primary_key if unquote(inbound?),
                     do: {:id, :binary_id, autogenerate: true},
                     else: {:session_id, :string, []}
      schema unquote(table) do
        if unquote(inbound?), do: field(:session_id, :string)
        field(:session, :map, virtual: true)
        field(:session_key, :string)
        field(:owner_id, :binary_id)
        field(:room_id, :string)
        field(:sender_key, :string)

        if unquote(counted?), do: field(:message_count, :integer, default: 0)

        field(:pickle, :binary)
        field(:pickle_data, :map, source: :pickle)
        timestamps()
      end

      @castable [:session_id, :session_key, :owner_id, :room_id, :sender_key, :pickle] ++
                  if(unquote(counted?), do: [:message_count], else: [])

      def changeset(megolm_session, attrs \\ %{}) do
        megolm_session
        |> cast(attrs, @castable)
        |> validate_required([:session_id, :session_key, :pickle])
      end
    end
  end
end
