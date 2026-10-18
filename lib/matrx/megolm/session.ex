defmodule Matrx.Megolm.Session do
  @moduledoc "Helper macro module to represent inbound and outbound session"

  defmacro __using__(schema_name) do
    quote location: :keep do
      use Ecto.Schema
      import Ecto.Changeset

      @derive {Inspect, [except: [:pickle, :pickle_data]]}

      @primary_key {:session_id, :string, []}
      schema unquote(schema_name) do
        field(:session, :map, virtual: true)
        field(:session_key, :string)
        # field :room_id, :string
        # field :message_index, :integer

        # belongs_to :user, Matrx.User,
        #   foreign_key: :user_id,
        #   type: :string,
        #   references: :user_id

        field(:pickle, :binary)
        field(:pickle_data, :map, source: :pickle)
        timestamps()
      end

      def changeset(outbound_megolm_session, attrs \\ %{}) do
        outbound_megolm_session
        |> cast(attrs, [
          :session_id,
          :session_key,
          # :room_id,
          # :user_id,
          :pickle
        ])
        |> validate_required([
          :session_id,
          :session_key,
          # :room_id, :user_id,
          :pickle
        ])
      end
    end
  end
end
