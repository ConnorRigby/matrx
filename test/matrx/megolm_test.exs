defmodule Matrx.MegolmTest do
  use Matrx.RepoCase, async: true
  alias Matrx.Megolm

  describe "session creation" do
    test "creates an outbound group session" do
      {:ok, outbound_session} = Megolm.create_outbound_session()
      assert outbound_session.session_id
    end

    test "session ids are unique" do
      {:ok, session_1} = Megolm.create_outbound_session()
      {:ok, session_2} = Megolm.create_outbound_session()

      refute session_1.session_id == session_2.session_id
    end

    test "exports an initial session key" do
      {:ok, session} = Megolm.create_outbound_session()
      assert is_binary(session.session_key)
      assert byte_size(session.session_key) > 0
    end
  end

  describe "basic encryption" do
    setup do
      {:ok, outbound} = Megolm.create_outbound_session()
      {:ok, inbound} = Megolm.create_inbound_session(outbound.session_id, outbound.session_key)
      %{outbound: outbound, inbound: inbound}
    end

    test "encrypts and decrypts a message", %{
      outbound: outbound,
      inbound: inbound
    } do
      {:ok, outbound, message} = Megolm.encrypt(outbound, "hello world")
      assert {:ok, inbound, "hello world"} = Megolm.decrypt(inbound, message)
      assert outbound
      assert inbound
    end

    test "unicode plaintext round trips", %{
      outbound: outbound,
      inbound: inbound
    } do
      plaintext = "hello 👋 世界"
      {:ok, outbound, message} = Megolm.encrypt(outbound, plaintext)
      assert {:ok, _inbound, ^plaintext} = Megolm.decrypt(inbound, message)
      assert outbound
    end
  end

  describe "ratchet" do
    test "multiple messages decrypt in order" do
      {:ok, outbound} = Megolm.create_outbound_session()
      {:ok, inbound} = Megolm.create_inbound_session(outbound.session_id, outbound.session_key)

      {messages, outbound} =
        Enum.map_reduce(1..100, outbound, fn i, session ->
          {:ok, session, message} =
            Megolm.encrypt(session, "message #{i}")

          {message, session}
        end)

      {plaintexts, _inbound} =
        Enum.map_reduce(messages, inbound, fn message, session ->
          {:ok, session, plaintext} =
            Megolm.decrypt(session, message)

          {plaintext, session}
        end)

      assert plaintexts == Enum.map(1..100, &"message #{&1}")

      assert outbound
    end

    test "each encrypted message has a different ciphertext" do
      {:ok, outbound} = Megolm.create_outbound_session()

      {:ok, outbound, first} =
        Megolm.encrypt(outbound, "same")

      {:ok, _outbound, second} =
        Megolm.encrypt(outbound, "same")

      refute first == second
    end

    # test "message indexes advance" do
    #   outbound = Megolm.new_outbound_session()

    #   assert Megolm.message_index(outbound) == 0

    #   {outbound, _} =
    #     Megolm.encrypt(outbound, "one")

    #   assert Megolm.message_index(outbound) == 1

    #   {outbound, _} =
    #     Megolm.encrypt(outbound, "two")

    #   assert Megolm.message_index(outbound) == 2
    # end
  end

  describe "inbound session" do
    test "an inbound session can decrypt messages starting from its exported key" do
      {:ok, outbound} = Megolm.create_outbound_session()

      {:ok, outbound, first} = Megolm.encrypt(outbound, "first")
      {:ok, outbound, second} = Megolm.encrypt(outbound, "second")
      {:ok, inbound} = Megolm.create_inbound_session(outbound.session_id, outbound.session_key)
      assert {:ok, inbound, "first"} = Megolm.decrypt(inbound, first)
      assert {:ok, _inbound, "second"} = Megolm.decrypt(inbound, second)
      assert outbound
    end
  end

  test "Megolm can advance over skipped message indexes" do
    {:ok, outbound} = Megolm.create_outbound_session()
    {:ok, inbound} = Megolm.create_inbound_session(outbound.session_id, outbound.session_key)
    {:ok, outbound, first} = Megolm.encrypt(outbound, "first")
    {:ok, outbound, second} = Megolm.encrypt(outbound, "second")
    {:ok, outbound, third} = Megolm.encrypt(outbound, "third")
    assert {:ok, inbound, "first"} = Megolm.decrypt(inbound, first)
    assert {:ok, inbound, "third"} = Megolm.decrypt(inbound, third)
    assert {:ok, _inbound, "second"} = Megolm.decrypt(inbound, second)

    assert outbound
  end
end
