defmodule Matrx.SyncDelivery do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "sync_deliveries" do
    belongs_to :owner, Matrx.Session, type: :binary_id, primary_key: true
    field :room_id, :string, primary_key: true
    field :event_id, :string, primary_key: true
    field :phase, :string, primary_key: true
  end

  def claim(session, room_id, event, phase \\ nil) do
    phase = phase || if(event.type == "m.room.encrypted", do: "encrypted", else: "clear")

    {count, _} =
      Matrx.Repo.insert_all(
        __MODULE__,
        [%{owner_id: session.id, room_id: room_id, event_id: event.event_id, phase: phase}],
        on_conflict: :nothing,
        conflict_target: [:owner_id, :room_id, :event_id, :phase]
      )

    count == 1
  end
end
