defmodule Matrx.Repo.Migrations.AddOutboundMegolmSharing do
  use Ecto.Migration

  def change do
    alter table(:megolm_outbound_sessions) do
      add :message_count, :integer, null: false, default: 0
    end

    # The devices a session's key was sent to
    create table(:megolm_outbound_shares, primary_key: false) do
      add :session_id,
          references(:megolm_outbound_sessions,
            column: :session_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false,
          primary_key: true

      add :user_id, :string, null: false, primary_key: true
      add :device_id, :string, null: false, primary_key: true
      timestamps(updated_at: false)
    end
  end
end
