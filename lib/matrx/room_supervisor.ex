defmodule Matrx.RoomSupervisor do
  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_room(room_id, opts \\ []) do
    case whereis(room_id) do
      nil ->
        spec = {Matrx.Room, Keyword.put(opts, :room_id, room_id)}
        DynamicSupervisor.start_child(__MODULE__, spec)

      pid ->
        {:ok, pid}
    end
  end

  def stop_room(room_id) do
    case whereis(room_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  def whereis(room_id) do
    case Registry.lookup(Matrx.RoomRegistry, room_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
