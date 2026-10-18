defmodule Matrx.Olm.Session do
  defmacro __using__(schema_name) do
    quote location: :keep do
      use Ecto.Schema
      import Ecto.Changeset

      @type t :: %__MODULE__{
              session_id: String.t(),
              owner_id: Ecto.UUID.t() | nil,
              sender_key: String.t() | nil,
              # user_id: String.t(),
              # user: Ecto.Association.NotLoaded.t() | User.t(),
              # device_id: String.t(),
              # device: Ecto.Association.NotLoaded.t() | Device.t(),
              session: Vodozemac.session(),
              # sender_key: String.t(),
              # recipient_key: String.t(),
              pickle: String.t(),
              pickle_data: map(),
              inserted_at: DateTime.t(),
              updated_at: DateTime.t()
            }

      @derive {Inspect, [except: [:pickle, :pickle_data]]}

      @primary_key {:session_id, :string, []}
      schema unquote(schema_name) do
        field(:session, :map, virtual: true)
        field(:pickle, :binary)
        field(:pickle_data, :map, source: :pickle)
        field(:owner_id, :binary_id)
        field(:sender_key, :string)
        # field :recipient_key, :string

        # belongs_to :device, Matrx.Device,
        #   foreign_key: :device_id,
        #   type: :string,
        #   references: :device_id

        # belongs_to :user, Matrx.User,
        #   foreign_key: :user_id,
        #   type: :string,
        #   references: :user_id

        timestamps()
      end

      def changeset(olm_session, attrs \\ %{}) do
        olm_session
        |> cast(attrs, [
          :session_id,
          :pickle,
          :owner_id,
          :sender_key
          # :device_id, :user_id,
          # :sender_key, :recipient_key
        ])
        |> validate_required([
          :session_id
          # :device_id, :user_id,
          # :sender_key, :recipient_key
        ])
      end
    end
  end
end
