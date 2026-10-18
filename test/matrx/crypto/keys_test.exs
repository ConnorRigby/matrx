defmodule Matrx.Crypto.KeysTest do
  use Matrx.RepoCase, async: true

  alias Matrx.Crypto.Keys
  alias Matrx.{Olm, Session}

  defmodule UploadAPI do
    def upload_keys(_session, body) do
      send(self(), {:upload, body})
      count = map_size(body["one_time_keys"])
      {:ok, %Matrx.API.OneTimeKeyCounts{one_time_key_counts: %{signed_curve25519: count}}}
    end
  end

  setup do
    {:ok, account} = Olm.create_account()
    login = %{access_token: "tok", device_id: "DEV1", user_id: "@alice:example.org"}
    {:ok, session} = Session.create("http://example.org", account, login)
    {:ok, session: session}
  end

  defp verify(session, object, signing_key) do
    sig = object["signatures"][session.user_id]["ed25519:#{session.device_id}"]
    payload = object |> Map.drop(["signatures", "unsigned"]) |> Jcs.encode()
    {:ok, sig} = Base.decode64(sig, padding: false)
    {:ok, pub} = Base.decode64(signing_key, padding: false)
    Ed25519.valid_signature?(sig, payload, pub)
  end

  test "device_keys are self signed and contain identity keys", %{session: session} do
    keys = Keys.device_keys(session)
    ids = Olm.identity_keys(session.account)

    assert keys["user_id"] == "@alice:example.org"
    assert keys["device_id"] == "DEV1"
    assert keys["keys"]["curve25519:DEV1"] == ids.curve25519
    assert keys["keys"]["ed25519:DEV1"] == ids.ed25519
    assert "m.megolm.v1.aes-sha2" in keys["algorithms"]
    assert verify(session, keys, ids.ed25519)
  end

  test "signing ignores existing signatures and unsigned", %{session: session} do
    ed = Olm.identity_keys(session.account).ed25519
    signed = Keys.sign_object(session, %{"a" => 1, "unsigned" => %{"x" => 1}})
    assert verify(session, signed, ed)
    assert signed["unsigned"] == %{"x" => 1}
  end

  test "one-time keys are signed", %{session: session} do
    Olm.generate_one_time_keys(session.account, 3)
    keys = Keys.signed_one_time_keys(session)
    ed = Olm.identity_keys(session.account).ed25519
    assert map_size(keys) == 3

    for {"signed_curve25519:" <> _, key} <- keys do
      assert verify(session, key, ed)
    end
  end

  test "upload sends device keys and tops up to 50, then marks published", %{session: session} do
    assert {:ok, 50} = Keys.upload(session, api: UploadAPI)

    assert_receive {:upload,
                    %{"device_keys" => %{"device_id" => "DEV1"}, "one_time_keys" => otks}}

    assert map_size(otks) == 50
    assert Vodozemac.one_time_keys(session.account.account) == %{}

    # persisted, so a reload doesn't regenerate or republish
    {:ok, reloaded} = Session.get(session.user_id, session.device_id)
    assert Vodozemac.one_time_keys(reloaded.account.account) == %{}
  end

  test "replenish does nothing when server has enough", %{session: session} do
    assert :ok = Keys.maybe_replenish(session, 25, api: UploadAPI)
    refute_receive {:upload, _}
  end

  test "replenish uploads only the missing keys without device keys", %{session: session} do
    assert {:ok, 30} = Keys.maybe_replenish(session, 20, api: UploadAPI)
    assert_receive {:upload, body}
    refute Map.has_key?(body, "device_keys")
    assert map_size(body["one_time_keys"]) == 30
  end
end
