defmodule Matrx.Repo.Migrations.AddOwnershipToOlmAndMegolmSessions do
  use Ecto.Migration

  def change do
    for table <- [:olm_inbound_sessions, :olm_outbound_sessions] do
      alter table(table) do
        # the logged in `Matrx.Session` this Olm session belongs to
        add :owner_id, references(:sessions, type: :binary_id, on_delete: :delete_all)
        # the peer's curve25519 identity key
        add :sender_key, :string
      end

      create index(table, [:owner_id, :sender_key])
    end

    for table <- [:megolm_inbound_sessions, :megolm_outbound_sessions] do
      alter table(table) do
        add :owner_id, references(:sessions, type: :binary_id, on_delete: :delete_all)
        add :room_id, :string
        # the curve25519 key of the device that created the megolm session
        add :sender_key, :string
      end

      create index(table, [:owner_id, :room_id])
    end
  end
end
