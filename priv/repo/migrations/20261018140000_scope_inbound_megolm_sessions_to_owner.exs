defmodule Matrx.Repo.Migrations.ScopeInboundMegolmSessionsToOwner do
  use Ecto.Migration

  # session_id was the primary key, so two logged in devices on one database
  # couldn't both hold the same room key. SQLite can't change a primary key in
  # place, so the table is rebuilt.
  def up do
    execute """
    CREATE TABLE megolm_inbound_sessions_new (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL,
      session_key TEXT NOT NULL,
      pickle JSON NOT NULL,
      owner_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
      room_id TEXT,
      sender_key TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO megolm_inbound_sessions_new
      (id, session_id, session_key, pickle, owner_id, room_id, sender_key, inserted_at, updated_at)
    SELECT
      lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) ||
        '-a' || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6))),
      session_id, session_key, pickle, owner_id, room_id, sender_key, inserted_at, updated_at
    FROM megolm_inbound_sessions
    """

    drop table(:megolm_inbound_sessions)
    rename table(:megolm_inbound_sessions_new), to: table(:megolm_inbound_sessions)

    create unique_index(:megolm_inbound_sessions, [:owner_id, :session_id])
    create unique_index(:megolm_inbound_sessions, [:owner_id, :session_key])
    create index(:megolm_inbound_sessions, [:owner_id, :room_id])
  end

  def down do
    raise Ecto.MigrationError, "irreversible: inbound sessions are now scoped to their owner"
  end
end
