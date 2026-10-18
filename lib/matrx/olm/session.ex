defmodule Matrx.Olm.Session do
  defmacro __using__(schema_name) do
    quote location: :keep do
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{
              session_id: String.t(),
              owner_id: Ecto.UUID.t() | nil,
              sender_key: String.t() | nil,
              session: Vodozemac.session(),
              pickle: String.t(),
              pickle_data: map(),
              inserted_at: DateTime.t(),
              updated_at: DateTime.t()
            }

      @derive {Inspect, [except: [:pickle, :pickle_data]]}

      @primary_key {:session_id, :string, []}
      schema unquote(schema_name) do
        field :session, :map, virtual: true
        field :pickle, :binary
        field :pickle_data, :map, source: :pickle
        field :sender_key, :string
        belongs_to :owner, Matrx.Session, type: :binary_id
        timestamps()
      end

      def changeset(olm_session, attrs \\ %{}) do
        olm_session
        |> cast(attrs, [
          :session_id,
          :pickle,
          :owner_id,
          :sender_key
        ])
        |> validate_required([:session_id])
      end
    end
  end
end
