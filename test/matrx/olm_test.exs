defmodule Matrx.OlmTest do
  use Matrx.RepoCase, async: true
  alias Matrx.Olm

  describe "account creation" do
    test "generates an identity key pair" do
      assert {:ok, alice} = Olm.create_account()

      assert is_binary(Olm.identity_keys(alice).curve25519)
      assert is_binary(Olm.identity_keys(alice).ed25519)
    end
  end

  describe "one-time keys" do
    test "generates one-time keys" do
      assert {:ok, account} = Olm.create_account()

      otks = Olm.generate_one_time_keys(account, 10)

      assert length(otks.created) == 10
      assert length(otks.removed) == 0
    end
  end

  describe "session establishment" do
    test "Alice can establish an outbound session with Bob" do
      assert {:ok, alice} = Olm.create_account()
      assert {:ok, bob} = Olm.create_account()

      %{curve25519: bob_public_key} = Olm.identity_keys(bob)
      assert %{created: [bob_otk]} = Olm.generate_one_time_keys(bob, 1)

      assert alice.account

      assert {:ok, alice_session} =
               Olm.create_outbound_session(
                 alice,
                 bob_public_key,
                 bob_otk
               )

      assert alice_session
    end

    test "Bob can create an inbound session from Alice's pre-key message" do
      assert {:ok, alice} = Olm.create_account()
      %{curve25519: alice_public_key} = Olm.identity_keys(alice)
      assert %{created: [_alice_otk]} = Olm.generate_one_time_keys(alice, 1)

      assert {:ok, bob} = Olm.create_account()
      %{curve25519: bob_public_key} = Olm.identity_keys(bob)
      assert %{created: [bob_otk]} = Olm.generate_one_time_keys(bob, 1)

      assert {:ok, alice_session} =
               Olm.create_outbound_session(
                 alice,
                 bob_public_key,
                 bob_otk
               )

      {:ok, alice_session, type, message} = Olm.encrypt(alice_session, "hello")

      assert type == 0

      assert {:ok, {decrypted, bob_session}} =
               Olm.create_inbound_session(
                 bob,
                 alice_public_key,
                 message
               )

      assert bob_session
      assert alice_session.session_id == alice_session.session_id
      assert decrypted == "hello"
    end
  end

  describe "normal messages" do
    setup :establish_session

    test "can encrypt and decrypt subsequent messages", %{
      alice: %{session: alice_session},
      bob: %{session: bob_session}
    } do
      {:ok, alice_session, type, message} = Olm.encrypt(alice_session, "second")
      assert type == 1
      assert {:ok, bob_session, "second"} = Olm.decrypt(bob_session, type, message)

      {:ok, alice_session, type, message} = Olm.encrypt(alice_session, "third")
      assert type == 1
      assert {:ok, bob_session, "third"} = Olm.decrypt(bob_session, type, message)

      assert alice_session
      assert bob_session
    end

    test "empty plaintext can be encrypted", %{
      alice: %{session: alice_session},
      bob: %{session: bob_session}
    } do
      {:ok, alice_session, type, message} = Olm.encrypt(alice_session, "")

      assert {:ok, bob_session, ""} = Olm.decrypt(bob_session, type, message)
      assert alice_session
      assert bob_session
    end

    test "unicode plaintext round trips", %{
      alice: %{session: alice_session},
      bob: %{session: bob_session}
    } do
      plaintext = "hello 👋 世界"
      {:ok, alice_session, type, message} = Olm.encrypt(alice_session, plaintext)

      assert {:ok, bob_session, ^plaintext} = Olm.decrypt(bob_session, type, message)
      assert alice_session
      assert bob_session
    end
  end

  describe "Olm ratchet" do
    setup :establish_session

    test "messages must be decrypted in the correct direction", %{
      alice: %{session: alice_session},
      bob: %{session: bob_session}
    } do
      {:ok, alice_session, type, message} = Olm.encrypt(alice_session, "hello")
      assert {:ok, bob_session, "hello"} = Olm.decrypt(bob_session, type, message)

      {:ok, bob_session, type, response} = Olm.encrypt(bob_session, "hello alice")

      assert {:ok, alice_session, "hello alice"} = Olm.decrypt(alice_session, type, response)
      assert alice_session
      assert bob_session
    end

    test "multiple messages advance the ratchet", %{
      alice: %{session: alice_session},
      bob: %{session: bob_session}
    } do
      {messages, alice_session} =
        Enum.reduce(1..100, {[], alice_session}, fn i, {acc, session} ->
          {:ok, session, type, message} = Olm.encrypt(session, "message #{i}")
          {acc ++ [{type, message}], session}
        end)

      {plaintexts, bob_session} =
        Enum.reduce(messages, {[], bob_session}, fn {type, message}, {acc, session} ->
          {:ok, session, plaintext} = Olm.decrypt(session, type, message)
          {acc ++ [plaintext], session}
        end)

      assert alice_session
      assert bob_session
      assert plaintexts == Enum.map(1..100, &"message #{&1}")
    end
  end

  test "messages can be decrypted out of order", tags do
    %{
      alice: %{session: alice_session},
      bob: %{session: bob_session}
    } = establish_session(tags)

    {:ok, alice_session, m1_type, m1_body} = Olm.encrypt(alice_session, "one")
    {:ok, alice_session, m2_type, m2_body} = Olm.encrypt(alice_session, "two")
    {:ok, alice_session, m3_type, m3_body} = Olm.encrypt(alice_session, "three")

    assert {:ok, bob_session, "one"} = Olm.decrypt(bob_session, m1_type, m1_body)
    assert {:ok, bob_session, "three"} = Olm.decrypt(bob_session, m3_type, m3_body)
    assert {:ok, bob_session, "two"} = Olm.decrypt(bob_session, m2_type, m2_body)
    assert alice_session
    assert bob_session
  end

  def establish_session(_tags) do
    assert {:ok, alice} = Olm.create_account()
    %{curve25519: alice_public_key} = Olm.identity_keys(alice)
    assert %{created: [_alice_otk]} = Olm.generate_one_time_keys(alice, 1)

    assert {:ok, bob} = Olm.create_account()
    %{curve25519: bob_public_key} = Olm.identity_keys(bob)
    assert %{created: [bob_otk]} = Olm.generate_one_time_keys(bob, 1)

    # Alice -> Bob: establish session
    assert {:ok, alice_out_to_bob_session} =
             Olm.create_outbound_session(alice, bob_public_key, bob_otk)

    assert {:ok, alice_out_to_bob_session, 0, message} =
             Olm.encrypt(alice_out_to_bob_session, "first from alice to bob")

    # alice_in_from_bob_session is created by bob
    assert {:ok, {"first from alice to bob", alice_in_from_bob_session}} =
             Olm.create_inbound_session(bob, alice_public_key, message)

    # Bob -> Alice: establish session
    assert {:ok, alice_in_from_bob_session, 1, bob_message} =
             Olm.encrypt(alice_in_from_bob_session, "first from bob to alice")

    assert {:ok, alice_out_to_bob_session, "first from bob to alice"} =
             Olm.decrypt(alice_out_to_bob_session, 1, bob_message)

    # assert {:ok, bob_out_to_alice_session} = Olm.create_outbound_session(bob, alice_public_key, alice_otk)
    # assert {:ok, bob_out_to_alice_session, 0, message} = Olm.encrypt(bob_out_to_alice_session, "first from bob to alice")
    # assert {:ok, {"first from bob to alice", bob_in_from_alice_session}} = Olm.create_inbound_session(alice, bob_public_key, message)

    %{
      alice: %{account: alice, session: alice_out_to_bob_session},
      bob: %{account: bob, session: alice_in_from_bob_session}
    }
  end
end
