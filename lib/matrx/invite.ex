defmodule Matrx.Invite do
  @moduledoc """
  An invitation for the client's user to join a room.
  It is delivered to consumers as `{:room_invite, invite, ctx}`.

  The bot is in the room only after `accept/3`; set the `:auto_join` option of
  `Matrx.Client` to accept invites without writing a handler for them.
  """

  alias Matrx.API.Event.RoomMember
  alias Matrx.API.Sync.Rooms.InvitedRoom
  alias Matrx.Session

  @enforce_keys [:room_id, :user_id]
  defstruct [:room_id, :user_id, :inviter, :room_name, :is_direct, state: []]

  @type t :: %__MODULE__{
          room_id: String.t(),
          # the invited user, i.e. the client's
          user_id: String.t(),
          inviter: String.t() | nil,
          room_name: String.t() | nil,
          is_direct: boolean(),
          # the stripped state events the server shared about the room
          state: [Matrx.API.Sync.Rooms.StrippedStateEvent.t()]
        }

  @doc "Build an invite from an `m.room.member` invite of `user_id` in a sync response"
  @spec from_sync(String.t(), String.t(), InvitedRoom.t()) :: t()
  def from_sync(user_id, room_id, %InvitedRoom{invite_state: %{events: events}}) do
    member =
      Enum.find(events, &(&1.type == "m.room.member" and &1.state_key == user_id))

    name =
      Enum.find_value(events, fn
        %{type: "m.room.name", content: %{name: name}} when is_binary(name) -> name
        _ -> nil
      end)

    %__MODULE__{
      room_id: room_id,
      user_id: user_id,
      inviter: member && member.sender,
      room_name: name,
      is_direct: match?(%{content: %RoomMember{is_direct: true}}, member),
      state: events
    }
  end

  @doc "Join the room. Options: `:api`."
  @spec accept(Session.t(), t(), keyword()) :: :ok | {:error, term()}
  def accept(%Session{} = session, %__MODULE__{room_id: room_id}, opts \\ []) do
    Keyword.get(opts, :api, Matrx.API).join_room(session, room_id)
  end

  @doc "Reject the invite. Options: `:api`."
  @spec decline(Session.t(), t(), keyword()) :: :ok | {:error, term()}
  def decline(%Session{} = session, %__MODULE__{room_id: room_id}, opts \\ []) do
    Keyword.get(opts, :api, Matrx.API).leave_room(session, room_id)
  end
end
