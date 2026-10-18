defmodule Matrx.API.Sync.Rooms do
  alias Matrx.API.Sync.Rooms.InvitedRoom
  alias Matrx.API.Sync.Rooms.JoinedRoom
  alias Matrx.API.Sync.Rooms.KnockedRoom
  alias Matrx.API.Sync.Rooms.LeftRoom

  defstruct [:invite, :join, :knock, :leave]

  def from_response(response) do
    invite = if response["invite"], do: invite_from_response(response["invite"])
    join = if response["join"], do: join_from_response(response["join"])
    knock = if response["knock"], do: knock_from_response(response["knock"])
    leave = if response["leave"], do: leave_from_response(response["leave"])
    %__MODULE__{invite: invite, join: join, knock: knock, leave: leave}
  end

  defp invite_from_response(invite) do
    Map.new(invite, fn {room_id, invite} -> {room_id, InvitedRoom.from_response(invite)} end)
  end

  defp join_from_response(join) do
    Map.new(join, fn {room_id, join} -> {room_id, JoinedRoom.from_response(join)} end)
  end

  defp knock_from_response(knock) do
    Map.new(knock, fn {room_id, knock} -> {room_id, KnockedRoom.from_response(knock)} end)
  end

  defp leave_from_response(leave) do
    Map.new(leave, fn {room_id, leave} -> {room_id, LeftRoom.from_response(leave)} end)
  end
end
