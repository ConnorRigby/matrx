defmodule Matrx.PresenceTest do
  use ExUnit.Case, async: true

  alias Matrx.API.Event
  alias Matrx.Support.FakeAPI
  alias Matrx.{Presence, Session}

  defmodule FailingAPI do
    def get_presence(_session, _user_id), do: {:error, :forbidden}
    def set_presence(_session, _payload), do: {:error, :unavailable}
  end

  setup do
    host = "presence-#{System.unique_integer([:positive])}.example"
    {:ok, _feed} = FakeAPI.start_feed(host: host)

    session = %Session{
      id: Ecto.UUID.generate(),
      home_server_uri: URI.parse("http://#{host}"),
      user_id: "@bot:#{host}"
    }

    {:ok, session: session}
  end

  defp event(content) do
    Event.from_response(%{
      "type" => "m.presence",
      "sender" => "@alice:example.org",
      "content" => content
    })
  end

  test "normalizes all states and preserves optional false and zero values" do
    for {raw, status} <- [
          {"online", :online},
          {"offline", :offline},
          {"unavailable", :unavailable}
        ] do
      event =
        event(%{
          "presence" => raw,
          "status_msg" => "Working",
          "currently_active" => false,
          "last_active_ago" => 0,
          "custom" => "retained"
        })

      assert %Presence{
               user_id: "@alice:example.org",
               presence: ^status,
               status_msg: "Working",
               currently_active: false,
               last_active_ago: 0,
               observed_at: %DateTime{},
               event: ^event
             } = Presence.from_event(event)
    end
  end

  test "absent optional fields stay unknown" do
    assert %Presence{
             status_msg: nil,
             currently_active: nil,
             last_active_ago: nil
           } = Presence.from_event(event(%{"presence" => "offline"}))
  end

  test "cache is scoped to stored session and holds the latest observation", %{session: session} do
    other = %{session | id: Ecto.UUID.generate()}
    user_id = "@alice:example.org"
    assert :error = Presence.get_cached(session, user_id)
    :ok = Phoenix.PubSub.subscribe(Matrx.PubSub, Presence.topic(session))

    online = event(%{"presence" => "online", "status_msg" => "Hi"})
    assert :ok = Presence.sync(session, online)
    assert_receive {:presence_update, %Presence{presence: :online} = presence}
    assert {:ok, ^presence} = Presence.get_cached(session, user_id)
    assert :error = Presence.get_cached(other, user_id)
    assert :error = Presence.get_cached(session, "@unknown:example.org")

    assert :ok = Presence.sync(other, event(%{"presence" => "unavailable"}))
    refute_receive {:presence_update, _}

    offline = event(%{"presence" => "offline"})
    assert :ok = Presence.sync(session, offline)
    assert_receive {:presence_update, %Presence{presence: :offline} = latest}
    assert latest.status_msg == nil
    assert {:ok, ^latest} = Presence.get_cached(session, user_id)
    assert {:ok, %Presence{presence: :unavailable}} = Presence.get_cached(other, user_id)
  end

  test "fetch and set use the API without fabricating sync observations", %{session: session} do
    assert :ok = Presence.set(session, :online, status_msg: "Hi", api: FakeAPI)
    user_id = session.user_id

    assert_receive {:set_presence, ^user_id, %{"presence" => "online", "status_msg" => "Hi"}}

    assert {:ok, %Presence{user_id: ^user_id, presence: :online, status_msg: "Hi", event: nil}} =
             Presence.fetch(session, user_id, api: FakeAPI)

    assert :ok = Presence.set(session, :unavailable, api: FakeAPI)
    assert_receive {:set_presence, ^user_id, %{"presence" => "unavailable"} = payload}
    refute Map.has_key?(payload, "status_msg")
    assert {:ok, %Presence{status_msg: "Hi"}} = Presence.fetch(session, user_id, api: FakeAPI)

    assert :ok = Presence.set(session, :offline, status_msg: "", api: FakeAPI)
    assert_receive {:set_presence, ^user_id, %{"presence" => "offline", "status_msg" => ""}}
    assert :error = Presence.get_cached(session, user_id)
  end

  test "fetch and set propagate failures without changing cached presence", %{session: session} do
    assert :ok = Presence.sync(session, event(%{"presence" => "online"}))
    assert {:ok, previous} = Presence.get_cached(session, "@alice:example.org")

    assert {:error, :forbidden} =
             Presence.fetch(session, "@alice:example.org", api: FailingAPI)

    assert {:error, :unavailable} = Presence.set(session, :offline, api: FailingAPI)
    assert {:ok, ^previous} = Presence.get_cached(session, "@alice:example.org")
  end

  test "rejects invalid status messages before calling the API", %{session: session} do
    assert_raise ArgumentError, ~r/status_msg must be a string/, fn ->
      Presence.set(session, :online, status_msg: nil, api: FakeAPI)
    end

    refute_receive {:set_presence, _, _}
  end
end
