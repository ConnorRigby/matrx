defmodule Matrx.Message do
  @moduledoc """
  A message in a room: the struct handed to consumers, and the functions to
  send one. Counterpart of Nostrum's `Nostrum.Struct.Message` and
  `Nostrum.Api.Message`.

  Messages are sent with `Matrx.Room.send_event/5`, so they are encrypted when
  the room is, and the room must be known to the client (i.e. joined and synced).
  """

  alias Matrx.API.Event
  alias Matrx.API.Event.RoomMessage
  alias Matrx.{Room, Session}

  @enforce_keys [:id, :room_id, :author]
  defstruct [:id, :room_id, :author, :body, :msgtype, :timestamp, :reply_to, :event]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          room_id: String.t(),
          # the sender's Matrix user id, e.g. "@alice:example.org"
          author: String.t(),
          # nil for a message that could not be decrypted
          body: String.t() | nil,
          msgtype: String.t() | nil,
          timestamp: DateTime.t() | nil,
          # event id of the message this one replies to
          reply_to: String.t() | nil,
          # the event as received, for anything not covered above
          event: Event.t()
        }

  @doc "Build a message from a `m.room.message` or an undecryptable `m.room.encrypted` event"
  @spec from_event(String.t(), Event.t()) :: t()
  def from_event(room_id, %Event{} = event) do
    {body, msgtype, reply_to} =
      case event.content do
        %RoomMessage{body: body, msgtype: msgtype, reply_to: reply_to} ->
          {body, msgtype, reply_to}

        _ ->
          {nil, nil, nil}
      end

    %__MODULE__{
      id: event.event_id,
      room_id: room_id,
      author: event.sender,
      body: body,
      msgtype: msgtype,
      timestamp: timestamp(event.origin_server_ts),
      reply_to: reply_to,
      event: event
    }
  end

  @doc "Is the message from this session's own user?"
  @spec own?(t(), Session.t()) :: boolean()
  def own?(%__MODULE__{author: author}, %Session{user_id: user_id}), do: author == user_id

  @doc """
  Send a message to a room. `content` is the text, or a complete `m.room.message`
  content map, e.g. `%{"msgtype" => "m.notice", "body" => "hi"}`.

  Options: `:reply_to` (a `t:t/0` to reply to) and `:api`.
  """
  @spec create(Session.t(), String.t(), String.t() | map(), keyword()) ::
          {:ok, %{event_id: String.t()}} | {:error, term()}
  def create(%Session{} = session, room_id, content, opts \\ []) do
    content =
      content
      |> to_content()
      |> put_reply(Keyword.get(opts, :reply_to))

    Room.send_event(room_id, session, "m.room.message", content, Keyword.take(opts, [:api]))
  end

  @doc "Send a message as a reply to `message`, in the same room"
  @spec reply(Session.t(), t(), String.t() | map(), keyword()) ::
          {:ok, %{event_id: String.t()}} | {:error, term()}
  def reply(%Session{} = session, %__MODULE__{} = message, content, opts \\ []) do
    create(session, message.room_id, content, Keyword.put(opts, :reply_to, message))
  end

  @doc """
  Upload a file from the filesystem and send it as an image, video, audio or
  file message, depending on its type. The file is read into memory.

  Options are those of `create/4` and `Matrx.Media.upload/4` (`:content_type`,
  `:caption`, `:info`), plus `:filename` to send it under another name. Files
  are encrypted automatically in encrypted rooms.
  """
  @spec create_file(Session.t(), String.t(), Path.t(), keyword()) ::
          {:ok, %{event_id: String.t()}} | {:error, term()}
  def create_file(%Session{} = session, room_id, path, opts \\ []) do
    with {:ok, data} <- File.read(path) do
      filename = Keyword.get_lazy(opts, :filename, fn -> Path.basename(path) end)
      create_binary(session, room_id, data, filename, opts)
    end
  end

  @doc """
  Upload `data` and send it under `filename`. The filename's extension decides
  the type unless `:content_type` is given. See `create_file/4` for the options.
  """
  @spec create_binary(Session.t(), String.t(), binary(), String.t(), keyword()) ::
          {:ok, %{event_id: String.t()}} | {:error, term()}
  def create_binary(%Session{} = session, room_id, data, filename, opts \\ []) do
    with {:ok, encrypted?} <- encrypted?(room_id),
         media_opts =
           opts
           |> Keyword.take([:content_type, :caption, :info, :api])
           |> Keyword.put(:encrypt, encrypted?),
         {:ok, content} <- Matrx.Media.upload(session, data, filename, media_opts) do
      create(session, room_id, content, Keyword.take(opts, [:reply_to, :api]))
    end
  end

  # Checked before uploading, so nothing is uploaded for a room we can't send to
  defp encrypted?(room_id) do
    case Matrx.RoomSupervisor.whereis(room_id) do
      nil -> {:error, :unknown_room}
      _pid -> {:ok, match?({:ok, _}, Room.encryption_info(room_id))}
    end
  end

  defp to_content(text) when is_binary(text), do: %{"msgtype" => "m.text", "body" => text}
  defp to_content(%{} = content), do: content

  defp put_reply(content, nil), do: content

  defp put_reply(content, %__MODULE__{id: id}) when is_binary(id) do
    Map.put(content, "m.relates_to", %{"m.in_reply_to" => %{"event_id" => id}})
  end

  defp timestamp(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp timestamp(_), do: nil
end
