defmodule Matrx.MediaTest do
  # The room and sync processes use the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false

  alias Matrx.Crypto.RoomMessages
  alias Matrx.Support.FakeAPI
  alias Matrx.{Media, Message, Session, SyncLongPoll}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, alice} = Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)

    {:ok,
     feed: feed, alice: alice, bob: bob, room_id: "!#{System.unique_integer([:positive])}:#{host}"}
  end

  defp join_room(ctx, encrypted?) do
    start_supervised!({SyncLongPoll, [session: ctx.bob, api: FakeAPI]})

    state = fn type, key, content ->
      %{
        "type" => type,
        "state_key" => key,
        "sender" => "@x:y",
        "event_id" => "$s#{System.unique_integer([:positive])}",
        "origin_server_ts" => 1,
        "content" => content
      }
    end

    events =
      for u <- [ctx.alice.user_id, ctx.bob.user_id],
          do: state.("m.room.member", u, %{"membership" => "join"})

    events =
      if encrypted?,
        do: [state.("m.room.encryption", "", %{"algorithm" => RoomMessages.algorithm()}) | events],
        else: events

    FakeAPI.push_sync(ctx.feed, %{
      "next_batch" => "s1",
      "rooms" => %{
        "join" => %{
          ctx.room_id => %{"state" => %{"events" => events}, "timeline" => %{"events" => []}}
        }
      }
    })

    Enum.find_value(1..100, fn _ ->
      Process.sleep(20)

      if Matrx.RoomSupervisor.whereis(ctx.room_id) &&
           match?({:ok, _}, Matrx.Room.encryption_info(ctx.room_id)) == encrypted?,
         do: true
    end) || flunk("room state never arrived")
  end

  describe "Media" do
    test "picks the msgtype from the type of the file" do
      assert Media.msgtype(Media.content_type("a.png")) == "m.image"
      assert Media.msgtype(Media.content_type("a.jpg")) == "m.image"
      assert Media.msgtype(Media.content_type("a.mp4")) == "m.video"
      assert Media.msgtype(Media.content_type("a.webm")) == "m.video"
      assert Media.msgtype(Media.content_type("a.wav")) == "m.audio"
      assert Media.msgtype(Media.content_type("a.mp3")) == "m.audio"
      assert Media.msgtype(Media.content_type("a.pdf")) == "m.file"
      assert Media.msgtype(Media.content_type("noextension")) == "m.file"
    end

    test "uploads plain data and builds the content", ctx do
      assert {:ok, content} = Media.upload(ctx.alice, @png, "cat.png", api: FakeAPI)
      assert_receive {:upload_media, @png, "image/png", "cat.png"}

      assert %{
               "msgtype" => "m.image",
               "body" => "cat.png",
               "url" => "mxc://" <> _,
               "info" => %{"mimetype" => "image/png", "size" => 11}
             } = content

      refute Map.has_key?(content, "file")
      refute Map.has_key?(content, "filename")
    end

    test "a caption becomes the body and the filename its own field", ctx do
      assert {:ok, content} =
               Media.upload(ctx.alice, "RIFF", "clip.wav",
                 api: FakeAPI,
                 caption: "listen",
                 info: %{"duration" => 1200}
               )

      assert %{
               "msgtype" => "m.audio",
               "body" => "listen",
               "filename" => "clip.wav",
               "info" => %{"mimetype" => "audio/wav", "duration" => 1200, "size" => 4}
             } = content
    end

    test "content_type overrides the guess", ctx do
      assert {:ok, %{"msgtype" => "m.video"}} =
               Media.upload(ctx.alice, "x", "clip.bin", api: FakeAPI, content_type: "video/mp4")

      assert_receive {:upload_media, "x", "video/mp4", "clip.bin"}
    end

    test "encrypts the file and round-trips it", ctx do
      assert {:ok, content} =
               Media.upload(ctx.alice, @png, "cat.png", api: FakeAPI, encrypt: true)

      assert_receive {:upload_media, ciphertext, "application/octet-stream", "cat.png"}

      refute ciphertext == @png
      assert byte_size(ciphertext) == byte_size(@png)
      refute Map.has_key?(content, "url")

      assert %{"url" => "mxc://" <> _, "v" => "v2", "key" => %{"alg" => "A256CTR"}} =
               content["file"]

      assert content["info"]["mimetype"] == "image/png"

      assert {:ok, @png} = Media.decrypt(ciphertext, content["file"])
      assert {:error, :hash_mismatch} = Media.decrypt(ciphertext <> "x", content["file"])
      assert {:error, :invalid_file} = Media.decrypt(ciphertext, %{})
    end

    test "each encryption uses a fresh key and iv" do
      {_, a} = Media.encrypt("same")
      {_, b} = Media.encrypt("same")
      refute a["key"]["k"] == b["key"]["k"]
      refute a["iv"] == b["iv"]
    end
  end

  describe "Message.create_binary/5 and create_file/4" do
    test "send an image to an unencrypted room", ctx do
      join_room(ctx, false)

      assert {:ok, %{event_id: _}} =
               Message.create_binary(ctx.alice, ctx.room_id, @png, "cat.png", api: FakeAPI)

      room_id = ctx.room_id
      assert_receive {:upload_media, @png, "image/png", "cat.png"}

      assert_receive {:send_room_message, ^room_id, "m.room.message",
                      %{"msgtype" => "m.image", "url" => "mxc://" <> _}}
    end

    test "reads a file from the filesystem", ctx do
      join_room(ctx, false)
      path = Path.join(System.tmp_dir!(), "matrx_media_#{System.unique_integer([:positive])}.wav")
      File.write!(path, "RIFFdata")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, _} = Message.create_file(ctx.alice, ctx.room_id, path, api: FakeAPI)
      name = Path.basename(path)
      assert_receive {:upload_media, "RIFFdata", "audio/wav", ^name}

      assert_receive {:send_room_message, _, "m.room.message",
                      %{"msgtype" => "m.audio", "body" => ^name}}

      assert {:ok, _} =
               Message.create_file(ctx.alice, ctx.room_id, path, api: FakeAPI, filename: "hi.wav")

      assert_receive {:upload_media, "RIFFdata", "audio/wav", "hi.wav"}
    end

    test "a missing file is an error and uploads nothing", ctx do
      join_room(ctx, false)

      assert {:error, :enoent} =
               Message.create_file(ctx.alice, ctx.room_id, "/nonexistent/a.png", api: FakeAPI)

      refute_received {:upload_media, _, _, _}
    end

    test "replies with a file", ctx do
      join_room(ctx, false)
      original = %Message{id: "$q", room_id: ctx.room_id, author: "@a:x"}

      assert {:ok, _} =
               Message.create_binary(ctx.alice, ctx.room_id, @png, "a.png",
                 api: FakeAPI,
                 reply_to: original
               )

      assert_receive {:send_room_message, _, "m.room.message",
                      %{"m.relates_to" => %{"m.in_reply_to" => %{"event_id" => "$q"}}}}
    end

    test "encrypts the file when the room is encrypted", ctx do
      join_room(ctx, true)

      assert {:ok, _} =
               Message.create_binary(ctx.alice, ctx.room_id, @png, "cat.png", api: FakeAPI)

      assert_receive {:upload_media, ciphertext, "application/octet-stream", "cat.png"}
      refute ciphertext == @png
      assert_receive {:send_room_message, _, "m.room.encrypted", _}
    end

    test "fails for unknown rooms without uploading", ctx do
      assert {:error, :unknown_room} =
               Message.create_binary(ctx.alice, "!nope:x", @png, "a.png", api: FakeAPI)

      refute_received {:upload_media, _, _, _}
    end
  end
end
