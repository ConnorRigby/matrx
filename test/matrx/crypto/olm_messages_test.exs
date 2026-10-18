defmodule Matrx.Crypto.OlmMessagesTest do
  use Matrx.RepoCase, async: true

  alias Matrx.API.Event
  alias Matrx.Crypto.{Devices, OlmMessages}
  alias Matrx.Olm.{InboundSession, OutboundSession}
  alias Matrx.Support.FakeAPI
  alias Matrx.{Olm, Session}

  @opts [api: FakeAPI]

  setup do
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)
    uri = URI.parse("http://#{host}")
    {:ok, alice} = Session.register(uri, %{username: "alice", password: "pw"}, api: FakeAPI)
    {:ok, bob} = Session.register(uri, %{username: "bob", password: "pw"}, api: FakeAPI)

    # alice knows bob's devices; bob has never heard of alice
    Devices.track(alice, [bob.user_id])
    :ok = Devices.refresh(alice, @opts)
    [bobs_device] = Devices.list(alice, bob.user_id)

    {:ok, feed: feed, alice: alice, bob: bob, bobs_device: bobs_device}
  end

  # What bob's sync would deliver for messages alice produced
  defp event_for(sender, messages, recipient) do
    Event.from_response(%{
      "type" => "m.room.encrypted",
      "sender" => sender.user_id,
      "content" => messages[recipient.user_id][recipient.device_id]
    })
  end

  defp send_to(sender, recipient, device, type, content) do
    {:ok, messages, []} = OlmMessages.encrypt(sender, [{device, type, content}], @opts)
    event_for(sender, messages, recipient)
  end

  # An event from alice whose payload carries `overrides` over a valid one. Alice
  # really encrypts it, so only our own verification can catch the lie.
  defp forge(ctx, overrides) do
    our_keys = Olm.identity_keys(ctx.alice.account)

    payload =
      Map.merge(
        %{
          "type" => "m.dummy",
          "content" => %{},
          "sender" => ctx.alice.user_id,
          "sender_device" => ctx.alice.device_id,
          "keys" => %{"ed25519" => our_keys.ed25519},
          "recipient" => ctx.bob.user_id,
          "recipient_keys" => %{"ed25519" => Olm.identity_keys(ctx.bob.account).ed25519}
        },
        overrides
      )

    forge_raw(ctx, Jcs.encode(payload))
  end

  defp forge_raw(ctx, plaintext) do
    # a legit send first, so that alice has a session with bob
    {:ok, _, []} = OlmMessages.encrypt(ctx.alice, [{ctx.bobs_device, "m.dummy", %{}}], @opts)
    [row] = Repo.all(OutboundSession)
    {:ok, _row, type, body} = row |> Olm.load_session() |> Olm.encrypt(plaintext)

    Event.from_response(%{
      "type" => "m.room.encrypted",
      "sender" => ctx.alice.user_id,
      "content" => %{
        "algorithm" => OlmMessages.algorithm(),
        "sender_key" => Olm.identity_keys(ctx.alice.account).curve25519,
        "ciphertext" => %{
          Olm.identity_keys(ctx.bob.account).curve25519 => %{"type" => type, "body" => body}
        }
      }
    })
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  test "round trip: a new device is fetched, the session created and the content returned", ctx do
    event = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{"hello" => "bob"})

    assert %{"ciphertext" => ciphertext} = event.content |> Map.from_struct() |> stringify()
    assert [%{"type" => 0}] = Map.values(ciphertext)

    refute Devices.tracked?(ctx.bob, ctx.alice.user_id)
    assert {:ok, decrypted} = OlmMessages.decrypt(ctx.bob, event, @opts)
    assert decrypted.type == "m.dummy"
    assert decrypted.content == %{"hello" => "bob"}
    assert decrypted.sender == ctx.alice.user_id
    assert decrypted.sender_device.device_id == ctx.alice.device_id
    assert Devices.tracked?(ctx.bob, ctx.alice.user_id)
  end

  test "sessions are reused and persisted in both directions", ctx do
    first = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{"n" => 1})
    assert {:ok, %{content: %{"n" => 1}}} = OlmMessages.decrypt(ctx.bob, first, @opts)
    assert count(OutboundSession) == 1
    assert count(InboundSession) == 1

    # no reply from bob yet, so alice keeps sending pre-key messages on the same session
    second = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{"n" => 2})
    assert {:ok, %{content: %{"n" => 2}}} = OlmMessages.decrypt(ctx.bob, second, @opts)
    assert count(OutboundSession) == 1
    assert count(InboundSession) == 1

    # bob answers over his inbound session, without claiming any key
    [alices_device] = Devices.list(ctx.bob, ctx.alice.user_id)
    reply = send_to(ctx.bob, ctx.alice, alices_device, "m.dummy", %{"n" => 3})
    assert {:ok, %{content: %{"n" => 3}}} = OlmMessages.decrypt(ctx.alice, reply, @opts)
    assert count(OutboundSession) == 1
    assert count(InboundSession) == 1

    # once bob has replied alice's messages are no longer pre-key messages
    third = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{"n" => 4})
    assert [%{type: 1}] = Map.values(third.content.ciphertext)
    assert {:ok, %{content: %{"n" => 4}}} = OlmMessages.decrypt(ctx.bob, third, @opts)
  end

  test "sessions survive being reloaded from the database", ctx do
    first = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{"n" => 1})
    {:ok, _} = OlmMessages.decrypt(ctx.bob, first, @opts)

    {:ok, bob} = Session.get(ctx.bob.user_id, ctx.bob.device_id)
    {:ok, alice} = Session.get(ctx.alice.user_id, ctx.alice.device_id)
    second = send_to(alice, bob, ctx.bobs_device, "m.dummy", %{"n" => 2})
    assert {:ok, %{content: %{"n" => 2}}} = OlmMessages.decrypt(bob, second, @opts)
  end

  test "an event that is replayed is rejected", ctx do
    event = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{})
    assert {:ok, _} = OlmMessages.decrypt(ctx.bob, event, @opts)
    assert {:error, _} = OlmMessages.decrypt(ctx.bob, event, @opts)
  end

  test "the claimed one-time key is consumed and the account is saved", ctx do
    before = Vodozemac.one_time_keys(ctx.bob.account.account)
    assert map_size(before) == 0

    event = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{})
    assert {:ok, _} = OlmMessages.decrypt(ctx.bob, event, @opts)
    # the 50 published keys are not part of `one_time_keys/1` any more, so we can
    # only check that a second device can't reuse the same key
    assert {:ok, alice2} =
             Session.register(ctx.alice.home_server_uri, %{username: "alice2", password: "pw"},
               api: FakeAPI
             )

    Devices.track(alice2, [ctx.bob.user_id])
    :ok = Devices.refresh(alice2, @opts)
    [device] = Devices.list(alice2, ctx.bob.user_id)
    {:ok, messages, []} = OlmMessages.encrypt(alice2, [{device, "m.dummy", %{}}], @opts)
    assert {:ok, _} = OlmMessages.decrypt(ctx.bob, event_for(alice2, messages, ctx.bob), @opts)
  end

  describe "verification" do
    test "rejects a message whose sender is not the claimed user", ctx do
      event = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{})
      forged = %{event | sender: "@mallory:#{ctx.alice.home_server_uri.host}"}

      assert {:error, :sender_mismatch} = OlmMessages.decrypt(ctx.bob, forged, @opts)
      # nothing is kept for a message that failed verification
      assert count(InboundSession) == 0
    end

    # one test per case: a failed decrypt consumes bob's one-time key
    for {field, value, error} <- [
          {"recipient_keys", %{"ed25519" => String.duplicate("A", 43)}, :recipient_key_mismatch},
          {"keys", %{"ed25519" => String.duplicate("A", 43)}, :sender_key_mismatch},
          {"recipient", "@someone:else.example", :recipient_mismatch}
        ] do
      test "rejects a payload with a bad #{field}", ctx do
        event = forge(ctx, %{unquote(field) => unquote(Macro.escape(value))})
        assert {:error, unquote(error)} = OlmMessages.decrypt(ctx.bob, event, @opts)
        assert count(InboundSession) == 0
      end
    end

    for {payload, i} <-
          Enum.with_index(["not json", "[]", ~s({"type": 1, "content": {}}), ~s({"type": "x"})]) do
      test "rejects an invalid payload ##{i}", ctx do
        assert {:error, :invalid_payload} =
                 OlmMessages.decrypt(ctx.bob, forge_raw(ctx, unquote(payload)), @opts)
      end
    end

    test "rejects a message from a device the server does not list", ctx do
      FakeAPI.delete_device(ctx.feed, ctx.alice.user_id, ctx.alice.device_id)
      event = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{})

      assert {:error, :unknown_device} = OlmMessages.decrypt(ctx.bob, event, @opts)
      assert count(InboundSession) == 0
    end

    test "rejects a message not addressed to us", ctx do
      event = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{})

      {:ok, other} =
        Session.register(ctx.bob.home_server_uri, %{username: "c", password: "pw"}, api: FakeAPI)

      assert {:error, :not_for_us} = OlmMessages.decrypt(other, event, @opts)
    end
  end

  describe "malformed input" do
    test "garbage ciphertext is an error and leaves the account usable", ctx do
      for {type, body} <- [{0, "not base64!"}, {0, "AAAA"}, {1, "AAAA"}, {0, ""}] do
        event =
          Event.from_response(%{
            "type" => "m.room.encrypted",
            "sender" => ctx.alice.user_id,
            "content" => %{
              "algorithm" => OlmMessages.algorithm(),
              "sender_key" => Olm.identity_keys(ctx.alice.account).curve25519,
              "ciphertext" => %{
                Olm.identity_keys(ctx.bob.account).curve25519 => %{"type" => type, "body" => body}
              }
            }
          })

        assert {:error, _} = OlmMessages.decrypt(ctx.bob, event, @opts)
      end

      good = send_to(ctx.alice, ctx.bob, ctx.bobs_device, "m.dummy", %{"ok" => true})
      assert {:ok, %{content: %{"ok" => true}}} = OlmMessages.decrypt(ctx.bob, good, @opts)
    end

    test "unsupported algorithms and shapes are errors, not crashes", ctx do
      for content <- [
            %{"algorithm" => "m.megolm.v1.aes-sha2", "ciphertext" => "abc"},
            %{"algorithm" => OlmMessages.algorithm(), "ciphertext" => "abc"},
            %{"algorithm" => OlmMessages.algorithm(), "sender_key" => "k", "ciphertext" => %{}},
            %{}
          ] do
        event =
          Event.from_response(%{
            "type" => "m.room.encrypted",
            "sender" => ctx.alice.user_id,
            "content" => content
          })

        assert {:error, _} = OlmMessages.decrypt(ctx.bob, event, @opts)
      end
    end
  end

  describe "encrypt/3" do
    test "devices without a usable one-time key are reported, not fatal", ctx do
      ghost = %{ctx.bobs_device | device_id: "GHOST", curve25519: String.duplicate("B", 43)}

      assert {:ok, messages, [^ghost]} =
               OlmMessages.encrypt(
                 ctx.alice,
                 [{ctx.bobs_device, "m.dummy", %{}}, {ghost, "m.dummy", %{}}],
                 @opts
               )

      assert Map.keys(messages[ctx.bob.user_id]) == [ctx.bob.device_id]
    end

    test "a claimed key with a bad signature is not used", ctx do
      forged = %{ctx.bobs_device | ed25519: String.duplicate("C", 43)}

      assert {:ok, %{}, [^forged]} =
               OlmMessages.encrypt(ctx.alice, [{forged, "m.dummy", %{}}], @opts)

      assert count(OutboundSession) == 0
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)

  defp stringify_value(%{} = map) when not is_struct(map), do: stringify(map)
  defp stringify_value(other), do: other
end
