defmodule Matrx.Crypto.KeyRequestsTest do
  # The sync process touches the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false

  alias Matrx.API.Event
  alias Matrx.Crypto.{Devices, KeyRequests, OlmMessages, RoomMessages, ToDevice}
  alias Matrx.Megolm.{InboundSession, KeyRequest}
  alias Matrx.Support.FakeAPI
  alias Matrx.{Megolm, Olm, Room, Session, SyncLongPoll}

  @opts [api: FakeAPI]
  @room_id "!room:example.org"

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")

    login = fn user, device ->
      Session.login_password(uri, %{user: user}, "pw", [device_id: device] ++ @opts)
    end

    {:ok, phone} = login.("alice", "PHONE")
    {:ok, laptop} = login.("alice", "LAPTOP")
    {:ok, bob} = login.("bob", "BOBPHONE")

    for me <- [phone, laptop, bob] do
      Devices.track(me, [phone.user_id, bob.user_id])
      :ok = Devices.refresh(me, @opts)
    end

    # the phone has the key of a session that the laptop is missing
    {:ok, outbound} = Megolm.create_outbound_session()
    sender_key = Olm.identity_keys(bob.account).curve25519

    {:ok, held} =
      Megolm.create_inbound_session(outbound.session_id, outbound.session_key, %{
        owner_id: phone.id,
        room_id: @room_id,
        sender_key: sender_key
      })

    flush()

    {:ok,
     feed: feed,
     phone: phone,
     laptop: laptop,
     bob: bob,
     outbound: outbound,
     held: held,
     sender_key: sender_key}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp missing_event(ctx) do
    %{content: %{session_id: ctx.outbound.session_id, sender_key: ctx.sender_key}}
  end

  # The encrypted to-device event `from` would send to `to`
  defp to_device_event(from, to, type, content) do
    [device] = Enum.filter(Devices.list(from, to.user_id), &(&1.device_id == to.device_id))
    {:ok, messages, []} = OlmMessages.encrypt(from, [{device, type, content}], @opts)

    Event.from_response(%{
      "type" => "m.room.encrypted",
      "sender" => from.user_id,
      "content" => messages[to.user_id][to.device_id]
    })
  end

  defp forwarded_key(ctx, overrides \\ %{}) do
    exported = Vodozemac.export_inbound_group_session(Megolm.load_inbound(ctx.held).session)

    Map.merge(
      %{
        "algorithm" => RoomMessages.algorithm(),
        "room_id" => @room_id,
        "sender_key" => ctx.sender_key,
        "session_id" => ctx.outbound.session_id,
        "session_key" => exported,
        "sender_claimed_ed25519_key" => "unused",
        "forwarding_curve25519_key_chain" => []
      },
      overrides
    )
  end

  describe "request/3" do
    test "asks all of our own devices for the key", ctx do
      assert :ok = KeyRequests.request(ctx.laptop, [{@room_id, missing_event(ctx)}], @opts)

      assert_receive {:send_to_device, "m.room_key_request", messages}
      assert [{user_id, %{"*" => request}}] = Map.to_list(messages)
      assert user_id == ctx.laptop.user_id

      assert %{
               "action" => "request",
               "requesting_device_id" => "LAPTOP",
               "body" => %{
                 "algorithm" => "m.megolm.v1.aes-sha2",
                 "room_id" => @room_id,
                 "sender_key" => sender_key,
                 "session_id" => session_id
               }
             } = request

      assert sender_key == ctx.sender_key
      assert session_id == ctx.outbound.session_id
      assert %KeyRequest{id: id} = KeyRequests.get(ctx.laptop, session_id)
      assert request["request_id"] == id
    end

    test "asks for a key only once", ctx do
      event = {@room_id, missing_event(ctx)}
      :ok = KeyRequests.request(ctx.laptop, [event, event], @opts)
      :ok = KeyRequests.request(ctx.laptop, [event], @opts)

      assert_receive {:send_to_device, "m.room_key_request", _}
      refute_receive {:send_to_device, "m.room_key_request", _}, 50
    end

    test "does not ask for a key we hold", ctx do
      :ok = KeyRequests.request(ctx.phone, [{@room_id, missing_event(ctx)}], @opts)
      refute_receive {:send_to_device, "m.room_key_request", _}, 50
    end

    test "forgets a request that could not be sent so it is retried", ctx do
      defmodule FailingAPI do
        def send_to_device(_session, _txn, _body), do: {:error, :boom}
      end

      assert :ok =
               KeyRequests.request(ctx.laptop, [{@room_id, missing_event(ctx)}], api: FailingAPI)

      assert KeyRequests.get(ctx.laptop, ctx.outbound.session_id) == nil
    end
  end

  describe "m.forwarded_room_key" do
    setup ctx do
      :ok = KeyRequests.request(ctx.laptop, [{@room_id, missing_event(ctx)}], @opts)
      flush()
      :ok
    end

    test "stores a requested key, which then decrypts messages", ctx do
      event = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", forwarded_key(ctx))
      assert :ok = ToDevice.handle(ctx.laptop, event, @opts)

      stored =
        Repo.get_by(InboundSession, owner_id: ctx.laptop.id, session_id: ctx.outbound.session_id)

      assert stored.room_id == @room_id
      assert stored.sender_key == ctx.sender_key

      {:ok, _, ciphertext} = Megolm.encrypt(ctx.outbound, "from before")
      assert {:ok, _, "from before"} = Megolm.decrypt(Megolm.load_inbound(stored), ciphertext)
    end

    test "cancels the request once the key arrived", ctx do
      %KeyRequest{id: id} = KeyRequests.get(ctx.laptop, ctx.outbound.session_id)
      event = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", forwarded_key(ctx))
      :ok = ToDevice.handle(ctx.laptop, event, @opts)

      assert_receive {:send_to_device, "m.room_key_request", messages}

      assert %{
               "action" => "request_cancellation",
               "request_id" => ^id,
               "requesting_device_id" => "LAPTOP"
             } = messages[ctx.laptop.user_id]["*"]

      assert KeyRequests.get(ctx.laptop, ctx.outbound.session_id) == nil
    end

    test "a key from a regular m.room_key also cancels the request", ctx do
      content = %{
        "algorithm" => RoomMessages.algorithm(),
        "room_id" => @room_id,
        "session_id" => ctx.outbound.session_id,
        "session_key" => ctx.outbound.session_key
      }

      event = to_device_event(ctx.phone, ctx.laptop, "m.room_key", content)
      :ok = ToDevice.handle(ctx.laptop, event, @opts)

      assert_receive {:send_to_device, "m.room_key_request", messages}
      assert %{"action" => "request_cancellation"} = messages[ctx.laptop.user_id]["*"]
    end

    test "ignores a key forwarded by another user", ctx do
      event = to_device_event(ctx.bob, ctx.laptop, "m.forwarded_room_key", forwarded_key(ctx))
      assert {:error, :unexpected_forwarded_key} = ToDevice.handle(ctx.laptop, event, @opts)
      assert Repo.get_by(InboundSession, owner_id: ctx.laptop.id) == nil
    end

    test "ignores a key for a session or room we did not ask about", ctx do
      {:ok, other} = Megolm.create_outbound_session()

      {:ok, held} =
        Megolm.create_inbound_session(other.session_id, other.session_key, %{
          owner_id: ctx.phone.id
        })

      other_ctx = %{ctx | outbound: other, held: held}

      for content <- [
            forwarded_key(other_ctx),
            forwarded_key(ctx, %{"room_id" => "!x:example.org"})
          ] do
        event = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", content)
        assert {:error, :unexpected_forwarded_key} = ToDevice.handle(ctx.laptop, event, @opts)
      end

      assert Repo.get_by(InboundSession, owner_id: ctx.laptop.id) == nil
    end

    test "rejects a key that is not the session we asked for", ctx do
      {:ok, other} = Megolm.create_outbound_session()

      {:ok, held} =
        Megolm.create_inbound_session(other.session_id, other.session_key, %{
          owner_id: ctx.phone.id
        })

      content = forwarded_key(%{ctx | held: held}, %{"session_id" => ctx.outbound.session_id})
      event = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", content)

      assert {:error, :invalid_session_key} = ToDevice.handle(ctx.laptop, event, @opts)
      assert Repo.get_by(InboundSession, owner_id: ctx.laptop.id) == nil
    end

    test "rejects a malformed exported key", ctx do
      content = forwarded_key(ctx, %{"session_key" => "bm90IGEga2V5"})
      event = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", content)
      assert {:error, :invalid_session_key} = ToDevice.handle(ctx.laptop, event, @opts)
    end

    test "ignores a second forward once the request is fulfilled", ctx do
      first = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", forwarded_key(ctx))
      :ok = ToDevice.handle(ctx.laptop, first, @opts)

      again = to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", forwarded_key(ctx))
      assert {:error, :unexpected_forwarded_key} = ToDevice.handle(ctx.laptop, again, @opts)

      assert Repo.aggregate(
               from(s in InboundSession, where: s.owner_id == ^ctx.laptop.id),
               :count
             ) ==
               1
    end
  end

  describe "in sync" do
    setup ctx do
      room_id = @room_id
      Room.subscribe(room_id)

      start_supervised!(
        {SyncLongPoll, [session: ctx.laptop, api: FakeAPI, key_request_delay: 20]}
      )

      {:ok, room_id: room_id}
    end

    defp push(feed, extra) do
      FakeAPI.push_sync(
        feed,
        Map.put(extra, "next_batch", "s#{System.unique_integer([:positive])}")
      )
    end

    defp message_event(ctx) do
      plaintext =
        Jason.encode!(%{
          "type" => "m.room.message",
          "content" => %{"msgtype" => "m.text", "body" => "old news"},
          "room_id" => @room_id
        })

      {:ok, _, ciphertext} = Megolm.encrypt(ctx.outbound, plaintext)

      %{
        "type" => "m.room.encrypted",
        "event_id" => "$old",
        "sender" => ctx.bob.user_id,
        "origin_server_ts" => 1_700_000_000_000,
        "content" => %{
          "algorithm" => RoomMessages.algorithm(),
          "sender_key" => ctx.sender_key,
          "device_id" => ctx.bob.device_id,
          "session_id" => ctx.outbound.session_id,
          "ciphertext" => ciphertext
        }
      }
    end

    test "requests the key of an undecryptable message and decrypts once it is forwarded", ctx do
      push(ctx.feed, %{
        "rooms" => %{
          "join" => %{@room_id => %{"timeline" => %{"events" => [message_event(ctx)]}}}
        }
      })

      assert_receive %Event{type: "m.room.encrypted"}, 2000
      assert_receive {:send_to_device, "m.room_key_request", %{} = request}, 2000
      assert %{"action" => "request"} = request[ctx.laptop.user_id]["*"]

      forwarded =
        to_device_event(ctx.phone, ctx.laptop, "m.forwarded_room_key", forwarded_key(ctx))

      push(ctx.feed, %{"to_device" => %{"events" => [event_to_json(forwarded)]}})

      assert_receive %Event{type: "m.room.message", content: %{body: "old news"}}, 2000
      assert_receive {:send_to_device, "m.room_key_request", cancel}, 2000
      assert %{"action" => "request_cancellation"} = cancel[ctx.laptop.user_id]["*"]
    end

    test "does not request a key that arrives on its own in time", ctx do
      content = %{
        "algorithm" => RoomMessages.algorithm(),
        "room_id" => @room_id,
        "session_id" => ctx.outbound.session_id,
        "session_key" => ctx.outbound.session_key
      }

      key = to_device_event(ctx.bob, ctx.laptop, "m.room_key", content)

      push(ctx.feed, %{
        "rooms" => %{
          "join" => %{@room_id => %{"timeline" => %{"events" => [message_event(ctx)]}}}
        },
        "to_device" => %{"events" => [event_to_json(key)]}
      })

      assert_receive %Event{type: "m.room.message", content: %{body: "old news"}}, 2000
      refute_receive {:send_to_device, "m.room_key_request", _}, 200
    end

    defp event_to_json(%Event{} = e) do
      %{
        "type" => e.type,
        "sender" => e.sender,
        "content" => %{
          "algorithm" => e.content.algorithm,
          "sender_key" => e.content.sender_key,
          "ciphertext" =>
            Map.new(e.content.ciphertext, fn {k, c} ->
              {k, %{"type" => c.type, "body" => c.body}}
            end)
        }
      }
    end
  end
end
