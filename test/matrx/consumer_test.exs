defmodule Matrx.ConsumerTest do
  # The room and sync processes use the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false
  @moduletag :capture_log

  alias Matrx.API.Event
  alias Matrx.Consumer.Context
  alias Matrx.Support.FakeAPI
  alias Matrx.{Consumer, Message, Session, SyncLongPoll}

  defmodule Handler do
    @behaviour Matrx.Consumer

    @impl true
    def handle_event(event) do
      send(Application.fetch_env!(:matrx, :consumer_test_pid), {:handled, event})
      if elem(event, 0) == :event and elem(event, 1).event.type == "m.crash", do: raise("boom")
    end
  end

  setup do
    Application.put_env(:matrx, :consumer_test_pid, self())
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)
    room_id = "!#{System.unique_integer([:positive])}:#{host}"
    {:ok, feed: feed, bob: bob, room_id: room_id, ctx: %Context{session: bob}}
  end

  defp event(type, sender, content, extra \\ %{}) do
    Event.from_response(
      Map.merge(
        %{
          "type" => type,
          "event_id" => "$#{System.unique_integer([:positive])}",
          "sender" => sender,
          "origin_server_ts" => 1_700_000_000_000,
          "content" => content
        },
        extra
      )
    )
  end

  defp text(sender, body, extra \\ %{}),
    do: event("m.room.message", sender, %{"msgtype" => "m.text", "body" => body}, extra)

  describe "translate/4" do
    test "turns messages into message_create", ctx do
      event =
        event("m.room.message", "@alice:x", %{
          "msgtype" => "m.text",
          "body" => "hi",
          "m.relates_to" => %{"m.in_reply_to" => %{"event_id" => "$parent"}}
        })

      assert {:message_create, %Message{} = message, context} =
               Consumer.translate("!r:x", event, ctx.ctx)

      assert context == ctx.ctx

      assert message.room_id == "!r:x"
      assert message.author == "@alice:x"
      assert message.body == "hi"
      assert message.msgtype == "m.text"
      assert message.reply_to == "$parent"
      assert message.id == event.event_id
      assert message.timestamp == ~U[2023-11-14 22:13:20.000Z]
    end

    test "leaves out our own messages unless asked not to", ctx do
      own = text(ctx.bob.user_id, "echo")
      assert :skip = Consumer.translate("!r:x", own, ctx.ctx)
      assert {:message_create, _, _} = Consumer.translate("!r:x", own, ctx.ctx, ignore_own: false)
    end

    test "reports undecryptable messages", ctx do
      encrypted =
        event("m.room.encrypted", "@alice:x", %{
          "algorithm" => "m.megolm.v1.aes-sha2",
          "ciphertext" => "x",
          "session_id" => "s"
        })

      assert {:message_undecryptable, %Message{body: nil, author: "@alice:x"}, _} =
               Consumer.translate("!r:x", encrypted, ctx.ctx)
    end

    test "passes other events on and skips state events", ctx do
      reaction = event("m.reaction", "@alice:x", %{})

      assert {:event, %{room_id: "!r:x", event: ^reaction}, _} =
               Consumer.translate("!r:x", reaction, ctx.ctx)

      state = event("m.room.name", "@alice:x", %{"name" => "n"}, %{"state_key" => ""})
      assert :skip = Consumer.translate("!r:x", state, ctx.ctx)
    end
  end

  describe "the consumer process" do
    test "refuses a module that is not a handler", ctx do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_handler, String}} =
               Consumer.start_link(handler: String, session: ctx.bob)
    end

    test "hands synced messages to the handler", ctx do
      start_supervised!({Consumer, handler: Handler, session: ctx.bob})
      start_supervised!({SyncLongPoll, [session: ctx.bob, api: FakeAPI]})

      FakeAPI.push_sync(ctx.feed, %{
        "next_batch" => "s1",
        "rooms" => %{
          "join" => %{
            ctx.room_id => %{
              "timeline" => %{
                "events" => [
                  raw_text("@alice:x", "hello"),
                  raw_text(ctx.bob.user_id, "my own"),
                  %{
                    "type" => "m.room.topic",
                    "state_key" => "",
                    "sender" => "@alice:x",
                    "event_id" => "$topic",
                    "origin_server_ts" => 1,
                    "content" => %{"topic" => "t"}
                  },
                  %{
                    "type" => "m.crash",
                    "sender" => "@alice:x",
                    "event_id" => "$crash",
                    "origin_server_ts" => 1,
                    "content" => %{}
                  },
                  raw_text("@alice:x", "after the crash")
                ]
              }
            }
          }
        }
      })

      room_id = ctx.room_id

      assert_receive {:handled, {:message_create, %Message{body: "hello", room_id: ^room_id}, c}},
                     2000

      assert c.session.id == ctx.bob.id
      assert_receive {:handled, {:event, %{event: %Event{type: "m.crash"}}, _}}, 2000
      assert_receive {:handled, {:message_create, %Message{body: "after the crash"}, _}}, 2000
      refute_receive {:handled, {:message_create, %Message{body: "my own"}, _}}, 100
      refute_received {:handled, {:event, %{event: %Event{type: "m.room.topic"}}, _}}
    end
  end

  defp raw_text(sender, body) do
    %{
      "type" => "m.room.message",
      "event_id" => "$#{System.unique_integer([:positive])}",
      "sender" => sender,
      "origin_server_ts" => 1_700_000_000_000,
      "content" => %{"msgtype" => "m.text", "body" => body}
    }
  end

  describe "Message.create/4 and reply/4" do
    setup ctx do
      start_supervised!({SyncLongPoll, [session: ctx.bob, api: FakeAPI]})

      FakeAPI.push_sync(ctx.feed, %{
        "next_batch" => "s1",
        "rooms" => %{
          "join" => %{ctx.room_id => %{"timeline" => %{"events" => [raw_text("@a:x", "q")]}}}
        }
      })

      Enum.find_value(1..100, fn _ ->
        Process.sleep(20)
        Matrx.RoomSupervisor.whereis(ctx.room_id) || nil
      end) || flunk("room never arrived")

      :ok
    end

    test "sends text as an m.text message", ctx do
      assert {:ok, %{event_id: _}} = Message.create(ctx.bob, ctx.room_id, "hi", api: FakeAPI)
      room_id = ctx.room_id

      assert_receive {:send_room_message, ^room_id, "m.room.message",
                      %{"msgtype" => "m.text", "body" => "hi"} = content}

      refute Map.has_key?(content, "m.relates_to")
    end

    test "sends a given content map as it is", ctx do
      content = %{"msgtype" => "m.notice", "body" => "fyi"}
      assert {:ok, _} = Message.create(ctx.bob, ctx.room_id, content, api: FakeAPI)
      assert_receive {:send_room_message, _, "m.room.message", ^content}
    end

    test "replies to a message", ctx do
      original = Message.from_event(ctx.room_id, text("@a:x", "question", %{"event_id" => "$q"}))
      assert {:ok, _} = Message.reply(ctx.bob, original, "answer", api: FakeAPI)

      assert_receive {:send_room_message, _, "m.room.message",
                      %{
                        "body" => "answer",
                        "m.relates_to" => %{"m.in_reply_to" => %{"event_id" => "$q"}}
                      }}
    end

    test "fails for rooms that are not known", ctx do
      assert {:error, :unknown_room} = Message.create(ctx.bob, "!nope:x", "hi", api: FakeAPI)
    end
  end

  test "Message.own?/2", ctx do
    assert Message.own?(Message.from_event("!r", text(ctx.bob.user_id, "x")), ctx.bob)
    refute Message.own?(Message.from_event("!r", text("@a:x", "x")), ctx.bob)
  end
end
