defmodule Matrx.ClientTest do
  # The sync process uses the Repo, so the sandbox must be shared
  use Matrx.RepoCase, async: false
  @moduletag :capture_log

  alias Matrx.Support.FakeAPI
  alias Matrx.{Client, Message}

  defmodule Handler do
    @behaviour Matrx.Consumer

    @impl true
    def handle_event(event),
      do: send(Application.fetch_env!(:matrx, :client_test_pid), {:handled, event})
  end

  setup do
    Application.put_env(:matrx, :client_test_pid, self())
    host = "hs-#{System.unique_integer([:positive])}.example"
    {:ok, feed} = FakeAPI.start_feed(host: host)

    opts = [
      handler: Handler,
      homeserver: "http://#{host}",
      username: "bot",
      password: "pw",
      api: FakeAPI,
      migrate: false
    ]

    on_exit(fn -> Application.delete_env(:matrx, Client) end)
    {:ok, feed: feed, opts: opts, host: host}
  end

  defp room_with_message(room_id, body) do
    %{
      "next_batch" => "s#{System.unique_integer([:positive])}",
      "rooms" => %{
        "join" => %{
          room_id => %{
            "timeline" => %{
              "events" => [
                %{
                  "type" => "m.room.message",
                  "event_id" => "$m#{System.unique_integer([:positive])}",
                  "sender" => "@alice:example.org",
                  "origin_server_ts" => 1,
                  "content" => %{"msgtype" => "m.text", "body" => body}
                }
              ]
            }
          }
        }
      }
    }
  end

  test "logs in, syncs and delivers events to the handler", ctx do
    client = start_supervised!({Client, ctx.opts})
    session = Client.session(client)
    assert session.user_id == "@bot:#{ctx.host}"

    FakeAPI.push_sync(ctx.feed, room_with_message("!r:#{ctx.host}", "hello bot"))

    assert_receive {:handled, {:message_create, %Message{body: "hello bot"}, c}}, 2000
    assert c.session.id == session.id
  end

  test "a bare handler module takes everything else from the config", ctx do
    Application.put_env(:matrx, Client, Keyword.delete(ctx.opts, :handler))
    client = start_supervised!({Client, Handler})
    assert Client.session(client).user_id == "@bot:#{ctx.host}"
  end

  test "options in the child spec win over the config", ctx do
    Application.put_env(:matrx, Client, Keyword.put(ctx.opts, :username, "configured"))
    client = start_supervised!({Client, ctx.opts})
    assert Client.session(client).user_id == "@bot:#{ctx.host}"
  end

  test "reuses the stored device after a restart without needing the password", ctx do
    client = start_supervised!({Client, ctx.opts})
    first = Client.session(client)
    :ok = stop_supervised(Client)

    client = start_supervised!({Client, Keyword.delete(ctx.opts, :password)})
    assert Client.session(client).id == first.id
    assert Repo.aggregate(Matrx.Session, :count) == 1
  end

  test "logs in again when the server no longer knows the stored device", ctx do
    client = start_supervised!({Client, ctx.opts})
    first = Client.session(client)
    :ok = stop_supervised(Client)
    :ok = FakeAPI.delete_device(ctx.feed, first.user_id, first.device_id)

    client = start_supervised!({Client, ctx.opts})
    second = Client.session(client)
    refute second.device_id == first.device_id
    assert Repo.aggregate(Matrx.Session, :count) == 1

    :ok = stop_supervised(Client)
    :ok = FakeAPI.delete_device(ctx.feed, first.user_id, second.device_id)

    assert {:error, :password_required} =
             Client.start_link(Keyword.delete(ctx.opts, :password))
  end

  test "new_device: true logs in again", ctx do
    client = start_supervised!({Client, ctx.opts})
    first = Client.session(client)
    :ok = stop_supervised(Client)

    client = start_supervised!({Client, [new_device: true] ++ ctx.opts})
    refute Client.session(client).id == first.id
  end

  test "refuses to start without a password for a first login", ctx do
    assert {:error, :password_required} = Client.start_link(Keyword.delete(ctx.opts, :password))
    assert Repo.aggregate(Matrx.Session, :count) == 0
  end

  test "refuses to start with missing options", ctx do
    assert {:error, {:missing_options, [:homeserver]}} =
             Client.start_link(Keyword.delete(ctx.opts, :homeserver))
  end

  test "can be registered by name", ctx do
    start_supervised!({Client, [name: :bot_client] ++ ctx.opts})
    assert Client.session(:bot_client).user_id == "@bot:#{ctx.host}"
  end
end
