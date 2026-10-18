defmodule Matrx.Crypto.CrossSigningTest do
  use Matrx.RepoCase, async: true

  alias Matrx.API.Event
  alias Matrx.Crypto.{CrossSigning, Devices, KeyRequests, RoomMessages, ToDevice}
  alias Matrx.Megolm.InboundSession
  alias Matrx.Support.FakeAPI
  alias Matrx.{Megolm, Olm, Session}

  @opts [api: FakeAPI]
  @room_id "!room:example.org"

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")

    login = fn user, device ->
      {:ok, session} =
        Session.login_password(uri, %{user: user}, "pw", [device_id: device] ++ @opts)

      session
    end

    phone = login.("alice", "PHONE")
    laptop = login.("alice", "LAPTOP")
    bob = login.("bob", "BOBPHONE")

    for me <- [phone, laptop], do: refresh_all(me, [phone, laptop, bob])
    {:ok, feed: feed, phone: phone, laptop: laptop, bob: bob, uri: uri}
  end

  defp refresh_all(me, sessions) do
    Devices.track(me, Enum.map(sessions, & &1.user_id))
    Devices.mark_outdated(me, Enum.map(sessions, & &1.user_id))
    :ok = Devices.refresh(me, @opts)
  end

  describe "bootstrap/2" do
    test "uploads signed keys and trusts only our own signed device", ctx do
      assert :ok = CrossSigning.bootstrap(ctx.phone, @opts)
      assert CrossSigning.bootstrapped?(ctx.phone)

      assert_receive {:upload_signing_keys, user_id, body}
      assert user_id == ctx.phone.user_id

      assert %{"master_key" => master, "self_signing_key" => self, "user_signing_key" => user} =
               body

      [{"ed25519:" <> master_pub, _}] = Map.to_list(master["keys"])
      assert master["usage"] == ["master"]
      assert self["usage"] == ["self_signing"]
      assert user["usage"] == ["user_signing"]

      for object <- [self, user],
          do:
            assert(
              Matrx.Crypto.Keys.verify_object(object, ctx.phone.user_id, master_pub, master_pub)
            )

      assert Devices.trusted?(ctx.phone, ctx.phone.user_id, "PHONE")
      refute Devices.trusted?(ctx.phone, ctx.phone.user_id, "LAPTOP")
    end

    test "does not trust a device signed by keys we do not hold", ctx do
      :ok = CrossSigning.bootstrap(ctx.phone, @opts)

      # the laptop sees the same server keys but holds none of the private keys
      refresh_all(ctx.laptop, [ctx.phone])
      refute Devices.trusted?(ctx.laptop, ctx.phone.user_id, "PHONE")
    end

    test "refuses to replace existing keys unless told to", ctx do
      :ok = CrossSigning.bootstrap(ctx.phone, @opts)
      assert {:error, :already_bootstrapped} = CrossSigning.bootstrap(ctx.phone, @opts)
      assert {:error, :cross_signing_exists} = CrossSigning.bootstrap(ctx.laptop, @opts)

      assert :ok = CrossSigning.bootstrap(ctx.laptop, [reset: true] ++ @opts)
      refute Devices.trusted?(ctx.laptop, ctx.phone.user_id, "PHONE")
      assert Devices.trusted?(ctx.laptop, ctx.laptop.user_id, "LAPTOP")
    end

    test "answers the password challenge", ctx do
      FakeAPI.require_uia(ctx.feed, "hunter2")

      assert {:error, :password_required} = CrossSigning.bootstrap(ctx.phone, @opts)
      refute CrossSigning.bootstrapped?(ctx.phone)

      assert {:error, _} = CrossSigning.bootstrap(ctx.phone, [password: "wrong"] ++ @opts)
      refute CrossSigning.bootstrapped?(ctx.phone)

      assert :ok = CrossSigning.bootstrap(ctx.phone, [password: "hunter2"] ++ @opts)
      assert CrossSigning.bootstrapped?(ctx.phone)
    end
  end

  describe "sign_device/3" do
    test "trusts another of our devices", ctx do
      :ok = CrossSigning.bootstrap(ctx.phone, @opts)
      refute Devices.trusted?(ctx.phone, ctx.phone.user_id, "LAPTOP")

      assert :ok = CrossSigning.sign_device(ctx.phone, "LAPTOP", @opts)
      assert Devices.trusted?(ctx.phone, ctx.phone.user_id, "LAPTOP")
    end

    test "fails for unknown devices and before bootstrapping", ctx do
      assert {:error, :not_bootstrapped} = CrossSigning.sign_device(ctx.phone, "LAPTOP", @opts)
      :ok = CrossSigning.bootstrap(ctx.phone, @opts)
      assert {:error, :unknown_device} = CrossSigning.sign_device(ctx.phone, "NOPE", @opts)
    end
  end

  describe "answering key requests" do
    setup ctx do
      :ok = CrossSigning.bootstrap(ctx.phone, @opts)
      :ok = CrossSigning.sign_device(ctx.phone, "LAPTOP", @opts)

      {:ok, outbound} = Megolm.create_outbound_session()
      sender_key = Olm.identity_keys(ctx.bob.account).curve25519
      refresh_all(ctx.phone, [ctx.bob])

      {:ok, _} =
        Megolm.create_inbound_session(outbound.session_id, outbound.session_key, %{
          owner_id: ctx.phone.id,
          room_id: @room_id,
          sender_key: sender_key
        })

      # the laptop asks for the key
      flush()

      :ok =
        KeyRequests.request(
          ctx.laptop,
          [
            {@room_id, %{content: %{session_id: outbound.session_id, sender_key: sender_key}}}
          ],
          @opts
        )

      assert_receive {:send_to_device, "m.room_key_request", %{} = messages}
      request = messages[ctx.laptop.user_id]["*"]
      flush()

      {:ok, outbound: outbound, sender_key: sender_key, request: request}
    end

    defp flush do
      receive do
        _ -> flush()
      after
        0 -> :ok
      end
    end

    defp request_event(sender, content),
      do: %Event{type: "m.room_key_request", sender: sender, content: content}

    test "forwards the key to a trusted device, which can then use it", ctx do
      assert :ok =
               ToDevice.handle(ctx.phone, request_event(ctx.phone.user_id, ctx.request), @opts)

      assert_receive {:send_to_device, messages}
      encrypted = messages[ctx.laptop.user_id]["LAPTOP"]

      event =
        Event.from_response(%{
          "type" => "m.room.encrypted",
          "sender" => ctx.phone.user_id,
          "content" => encrypted
        })

      assert :ok = ToDevice.handle(ctx.laptop, event, @opts)

      stored =
        Repo.get_by(InboundSession, owner_id: ctx.laptop.id, session_id: ctx.outbound.session_id)

      assert stored.sender_key == ctx.sender_key

      {:ok, _, ciphertext} = Megolm.encrypt(ctx.outbound, "history")
      assert {:ok, _, "history"} = Megolm.decrypt(Megolm.load_inbound(stored), ciphertext)
      assert RoomMessages.algorithm() == "m.megolm.v1.aes-sha2"
    end

    test "does not answer an untrusted device", ctx do
      untrusted =
        Session.login_password(ctx.uri, %{user: "alice"}, "pw", [device_id: "TABLET"] ++ @opts)

      {:ok, tablet} = untrusted
      refresh_all(tablet, [tablet])
      request = %{ctx.request | "requesting_device_id" => "TABLET"}

      assert {:error, :untrusted_device} =
               ToDevice.handle(ctx.phone, request_event(ctx.phone.user_id, request), @opts)

      refute_received {:send_to_device, _}
    end

    test "does not answer other users or ourselves", ctx do
      assert :ok = ToDevice.handle(ctx.phone, request_event(ctx.bob.user_id, ctx.request), @opts)

      own = %{ctx.request | "requesting_device_id" => "PHONE"}
      assert :ok = ToDevice.handle(ctx.phone, request_event(ctx.phone.user_id, own), @opts)

      refute_received {:send_to_device, _}
    end

    test "does not forward a key for another room or sender, or one we lack", ctx do
      body = ctx.request["body"]

      for changed <- [
            %{"room_id" => "!other:example.org"},
            %{"sender_key" => "other"},
            %{"session_id" => "unknown"}
          ] do
        request = %{ctx.request | "body" => Map.merge(body, changed)}

        assert {:error, :unknown_key_or_device} =
                 ToDevice.handle(ctx.phone, request_event(ctx.phone.user_id, request), @opts)
      end

      refute_received {:send_to_device, _}
    end

    test "ignores cancellations", ctx do
      request = %{
        "action" => "request_cancellation",
        "request_id" => "x",
        "requesting_device_id" => "LAPTOP"
      }

      assert :ok = ToDevice.handle(ctx.phone, request_event(ctx.phone.user_id, request), @opts)
      refute_received {:send_to_device, _}
    end
  end
end
