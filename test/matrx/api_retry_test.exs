defmodule Matrx.APIRetryTest do
  use ExUnit.Case, async: false

  alias Matrx.{API, APIError}

  @moduletag :capture_log
  @session %{home_server_uri: URI.parse("https://matrix.example"), access_token: "token"}

  setup do
    original = Req.default_options()
    config = Application.fetch_env(:matrx, API)

    on_exit(fn ->
      Req.default_options(original)

      case config do
        {:ok, value} -> Application.put_env(:matrx, API, value)
        :error -> Application.delete_env(:matrx, API)
      end
    end)

    Application.put_env(:matrx, API, max_retries: 3)
    :ok
  end

  defp stub(responses) do
    parent = self()
    counter = :atomics.new(1, [])

    Req.default_options(
      adapter: fn request ->
        attempt = :atomics.add_get(counter, 1, 1)
        send(parent, {:attempt, attempt, System.monotonic_time(:millisecond), request})
        response = Enum.at(responses, attempt - 1) || List.last(responses)
        {request, response}
      end
    )
  end

  defp response(status, body, headers \\ []) do
    Req.Response.new(
      status: status,
      headers: [{"content-type", "application/json"} | headers],
      body: body |> :json.encode() |> IO.iodata_to_binary()
    )
  end

  defp limited(delay \\ 0) do
    response(429, %{
      "errcode" => "M_LIMIT_EXCEEDED",
      "error" => "Slow down",
      "retry_after_ms" => delay
    })
  end

  test "every endpoint retries rate limits and keeps its normal return shape" do
    login = %{
      "access_token" => "token",
      "device_id" => "DEVICE",
      "home_server" => "matrix.example",
      "user_id" => "@bot:matrix.example"
    }

    calls = [
      {fn -> API.get_profile(@session, "@bot:example") end, %{"displayname" => "Bot"}},
      {fn -> API.set_display_name(Map.put(@session, :user_id, "@bot:example"), "Bot") end, %{}},
      {fn ->
         API.set_avatar_url(Map.put(@session, :user_id, "@bot:example"), "mxc://example/a")
       end, %{}},
      {fn -> API.register(@session, %{username: "bot", password: "pw"}) end, login},
      {fn -> API.login_password(@session, %{type: "m.id.user", user: "bot"}, "pw") end, login},
      {fn -> API.whoami(@session) end, login},
      {fn -> API.create_room(@session, %{}) end, %{"room_id" => "!r:example"}},
      {fn -> API.join_room(@session, "!r:example") end, %{}},
      {fn -> API.leave_room(@session, "!r:example") end, %{}},
      {fn -> API.kick_room(@session, "!r:example", %{user_id: "@a:b"}) end, %{}},
      {fn -> API.send_room_message(@session, "!r:example", "txn", "m.room.message", %{}) end,
       %{"event_id" => "$sent"}},
      {fn -> API.send_to_device(@session, "txn", %{"messages" => %{}}) end, %{}},
      {fn -> API.upload_media(@session, <<0, 255>>, "audio/wav", "clip.wav") end,
       %{"content_uri" => "mxc://example/clip"}},
      {fn -> API.upload_keys(@session, %{}) end, %{}},
      {fn -> API.keys_query(@session, %{}) end, %{}},
      {fn -> API.claim_keys(@session, %{}) end, %{}},
      {fn -> API.upload_signing_keys(@session, %{}) end, %{}},
      {fn -> API.upload_signatures(@session, %{}) end, %{}},
      {fn -> API.list_devices(@session) end, %{"devices" => []}},
      {fn -> API.delete_devices(@session, %{"devices" => []}) end, %{}},
      {fn -> API.user_directory_search(@session, %{"search_term" => "bot"}) end, %{}},
      {fn -> API.sync(@session, %{since: "s0", timeout: 0}) end, %{"next_batch" => "s1"}}
    ]

    for {call, body} <- calls do
      stub([limited(), response(200, body)])
      result = call.()
      assert result == :ok or match?({:ok, _}, result)
      assert_receive {:attempt, 1, _, first}
      assert_receive {:attempt, 2, _, second}
      assert first.method == second.method
      assert first.url == second.url
      assert first.body == second.body
      assert first.headers == second.headers
      refute_receive {:attempt, 3, _, _}, 0
    end
  end

  test "waits at least retry_after_ms milliseconds before retrying" do
    stub([limited(40), response(200, %{"devices" => []})])
    assert {:ok, []} = API.list_devices(@session)
    assert_receive {:attempt, 1, before, _}
    assert_receive {:attempt, 2, after_retry, _}
    assert after_retry - before >= 40
  end

  test "profile updates use authenticated PUTs with encoded user IDs and correct fields" do
    session = Map.put(@session, :user_id, "@bot/a:example")

    for {call, field, value} <- [
          {fn -> API.set_display_name(session, "Böt") end, "displayname", "Böt"},
          {fn -> API.set_avatar_url(session, "") end, "avatar_url", ""}
        ] do
      stub([response(200, %{})])
      assert :ok = call.()
      assert_receive {:attempt, 1, _, request}
      assert request.method == :put
      assert request.url.path == "/_matrix/client/v3/profile/%40bot%2Fa%3Aexample/#{field}"
      assert :json.decode(IO.iodata_to_binary(request.body)) == %{field => value}
      assert Req.Request.get_header(request, "authorization") == ["Bearer token"]
    end

    stub([response(403, %{"errcode" => "M_FORBIDDEN", "error" => "Denied"})])
    assert {:error, %APIError{errcode: :m_forbidden}} = API.set_display_name(session, "Bot")
  end

  test "Retry-After takes precedence over the Matrix delay" do
    stub([
      response(429, %{"errcode" => "M_LIMIT_EXCEEDED", "retry_after_ms" => 5000}, [
        {"retry-after", "0"}
      ]),
      response(200, %{"devices" => []})
    ])

    task = Task.async(fn -> API.list_devices(@session) end)
    assert {:ok, []} = Task.await(task, 2000)
  end

  test "honors an HTTP-date Retry-After" do
    date = Calendar.strftime(DateTime.add(DateTime.utc_now(), 2), "%a, %d %b %Y %H:%M:%S GMT")
    expected = Req.Response.get_retry_after(response(429, %{}, [{"retry-after", date}]))
    stub([response(429, %{}, [{"retry-after", date}]), response(200, %{"devices" => []})])

    assert {:ok, []} = API.list_devices(@session)
    assert_receive {:attempt, 1, before, _}
    assert_receive {:attempt, 2, after_retry, _}
    assert after_retry - before >= expected - 50
  end

  test "malformed delay values use exponential backoff" do
    stub([
      response(429, %{"errcode" => "M_LIMIT_EXCEEDED", "retry_after_ms" => -1}, [
        {"retry-after", "invalid"}
      ]),
      response(429, %{"errcode" => "M_LIMIT_EXCEEDED", "retry_after_ms" => "bad"}),
      response(200, %{"devices" => []})
    ])

    assert {:ok, []} = API.list_devices(@session)
    assert_receive {:attempt, 1, first, _}
    assert_receive {:attempt, 2, second, _}
    assert_receive {:attempt, 3, third, _}
    assert second - first >= 1000
    assert third - second >= 2000
  end

  test "a Matrix rate-limit code is retried even without HTTP 429" do
    stub([
      response(400, %{"errcode" => "M_LIMIT_EXCEEDED", "retry_after_ms" => 0}),
      response(200, %{"devices" => []})
    ])

    assert {:ok, []} = API.list_devices(@session)
    assert_receive {:attempt, 2, _, _}
  end

  test "a non-JSON rate-limit response still retries using its header" do
    stub([
      Req.Response.new(
        status: 429,
        headers: [{"content-type", "text/html"}, {"retry-after", "0"}],
        body: "<html>Too many requests</html>"
      ),
      response(200, %{"devices" => []})
    ])

    assert {:ok, []} = API.list_devices(@session)
    assert_receive {:attempt, 1, _, _}
    assert_receive {:attempt, 2, _, _}
  end

  test "a non-JSON HTTP error is returned rather than raising during retry inspection" do
    stub([
      Req.Response.new(
        status: 403,
        headers: [{"content-type", "text/html"}],
        body: "<html>Forbidden</html>"
      )
    ])

    assert {:error, %APIError{errcode: :m_unknown}} =
             API.join_room(@session, "!r:example")
  end

  test "exhausted retries return the final error, with the delay" do
    stub([limited(0)])

    assert {:error, %APIError{errcode: :m_limit_exceeded, retry_after_ms: 0}} =
             API.list_devices(@session)

    for attempt <- 1..4, do: assert_receive({:attempt, ^attempt, _, _})
    refute_receive {:attempt, 5, _, _}, 0
  end

  test "zero retries disables retries" do
    Application.put_env(:matrx, API, max_retries: 0)
    stub([limited(0)])
    assert {:error, %APIError{errcode: :m_limit_exceeded}} = API.list_devices(@session)
    assert_receive {:attempt, 1, _, _}
    refute_receive {:attempt, 2, _, _}, 0
  end

  test "malformed numeric and repeated headers fall back to retry_after_ms" do
    for headers <- [
          [{"retry-after", "-1"}],
          [{"retry-after", "0.5"}],
          [{"retry-after", "0"}, {"retry-after", "1"}]
        ] do
      stub([
        response(429, %{"errcode" => "M_LIMIT_EXCEEDED", "retry_after_ms" => 0}, headers),
        response(200, %{"devices" => []})
      ])

      assert {:ok, []} = API.list_devices(@session)
      assert_receive {:attempt, 1, _, _}
      assert_receive {:attempt, 2, _, _}
    end
  end

  test "non-rate-limit errors and UIA challenges are not retried" do
    for status <- [400, 401, 403, 500, 503] do
      stub([response(status, %{"errcode" => "M_FORBIDDEN", "error" => "Denied"})])

      assert {:error, %APIError{errcode: :m_forbidden}} =
               API.join_room(@session, "!r:example")

      assert_receive {:attempt, 1, _, _}
      refute_receive {:attempt, 2, _, _}, 0
    end

    stub([response(401, %{"session" => "uia", "flows" => []})])
    assert {:error, {:uia_required, "uia"}} = API.upload_signing_keys(@session, %{})
    assert_receive {:attempt, 1, _, _}
    refute_receive {:attempt, 2, _, _}, 0
  end

  test "POST transport errors aren't retried" do
    error = %Req.TransportError{reason: :closed}
    stub([error])
    assert {:error, ^error} = API.join_room(@session, "!r:example")
    assert_receive {:attempt, 1, _, _}
    refute_receive {:attempt, 2, _, _}, 0
  end

  test "GET retains Req's existing transient-error retries" do
    stub([
      response(503, %{"errcode" => "M_UNKNOWN", "error" => "Unavailable"}),
      response(200, %{"devices" => []})
    ])

    assert {:ok, []} = API.list_devices(@session)
    assert_receive {:attempt, 1, _, _}
    assert_receive {:attempt, 2, _, _}
  end
end
