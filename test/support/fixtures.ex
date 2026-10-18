defmodule Matrx.Support.Fixtures do
  def m_room_create() do
    """
    {
      "content": {
        "m.federate": true,
        "predecessor": {
          "event_id": "$something:example.org",
          "room_id": "!oldroom:example.org"
        },
        "room_version": "11"
      },
      "event_id": "$143273582443PhrSn:example.org",
      "origin_server_ts": #{ts()},
      "room_id": "!jEsUZKDJdhlrceRyVU:example.org",
      "sender": "@example:example.org",
      "state_key": "",
      "type": "m.room.create",
      "unsigned": {
        "age": 1234,
        "membership": "join"
      }
    }
    """
    |> :json.decode()
    |> Matrx.API.Event.from_response()
  end

  def m_room_member(sender, displayname) do
    """
    {
      "content": {
        "avatar_url": "mxc://example.org/SEsfnsuifSDFSSEF",
        "displayname": "#{displayname}",
        "membership": "join",
        "reason": "Looking for support"
      },
      "event_id": "$143273582443PhrSn:example.org",
      "origin_server_ts": #{ts()},
      "room_id": "!jEsUZKDJdhlrceRyVU:example.org",
      "sender": "#{sender}",
      "state_key": "#{sender}",
      "type": "m.room.member",
      "unsigned": {
        "age": 1234,
        "membership": "join"
      }
    }
    """
    |> :json.decode()
    |> Matrx.API.Event.from_response()
  end

  def m_room_message(content) do
    """
    {
      "content": {
        "body": "#{content}",
        "format": "org.matrix.custom.html",
        "formatted_body": "<b>This is an example text message</b>",
        "msgtype": "m.text"
      },
      "event_id": "$143273582443PhrSn:example.org",
      "origin_server_ts": #{ts()},
      "room_id": "!jEsUZKDJdhlrceRyVU:example.org",
      "sender": "@example:example.org",
      "type": "m.room.message",
      "unsigned": {
        "age": 1234,
        "membership": "join"
      }
    }
    """
    |> :json.decode()
    |> Matrx.API.Event.from_response()
  end

  def ts, do: System.unique_integer([:monotonic, :positive])
end
