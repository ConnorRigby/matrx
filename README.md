# Matrx

Elixir library implementing a basic [Matrix](https://matrix.org/) client. It supports the following:

* End to end encryption, verification and cross signing
* Sending and receiving plaintext and end to end encrypted messages. Text and Media upload is supported
* Room membership: join, leave, kick, ban
* Presence updates: messages and fetching/setting presence

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `matrx` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:matrx, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/matrx>.

## IEx Usage

The simplest example usage is at the console. 
Make sure to set `MATRIX_PASSWORD` as an environment variable, or use the `password: ` option.

```elixir
import Matrx.Dev
session = connect("https://matrix.example.com", "username")
join(session, "!eiyZOmiCnUufWlRabT:matrix.example.com") # only needs to be done once
watch("!eiyZOmiCnUufWlRabT:matrix.example.com") # ensures that we are syncing the channel that was just joined.
say(session, "!eiyZOmiCnUufWlRabT:matrix.example.com", "hello from elixir") # send a message. It should have no warnings or errors reported by other clients.
```

## Usage

### Bootstrap a bot's verification

For an already registered, matrix account, run:

```sh
mix matrx.verify --homeserver https://matrix.example.com --username mybot
```

Set `MATRIX_PASSWORD` in the environment, or configure `:password` under
`config :matrx, Matrx.Client`.
It logs in, creates the cross-signing identity, and signs the device without
starting your bot application or syncing rooms.

### Set the bot's profile

```sh
mix matrx.profile --display-name "My Bot" --avatar ./avatar.png
# Or reuse an uploaded image:
mix matrx.profile --avatar-url mxc://matrix.example.com/media-id
# View the current profile:
mix matrx.profile
# Clear either field:
mix matrx.profile --display-name "" --avatar-url ""
```

Credentials and database selection work like `mix matrx.verify`. Use
`--homeserver` and `--username` to override the client config. Avatar files are
uploaded unencrypted as public profile media; MIME type is inferred from the
extension, or supplied with `--content-type image/png`. Only supplied fields
are changed. Changes are separate requests, so failures do not roll back an
earlier change. See `mix help matrx.profile`.

Pragmatic usage for example to create a simple bot:

```elixir
defmodule MyBot do
  @behaviour Matrx.Consumer

  @impl true
  def handle_event({:message_create, message, ctx}) do
    if message.body == "!ping", do: Matrx.Message.reply(ctx.session, message, "pong")
  end

  def handle_event(_event), do: :ok
end
```

In your applications supervision tree add: 

```elixir
children = [
  {Matrx.Client,
   handler: MyBot,
   homeserver: "https://matrix.example.com",
   username: "mybot",
   password: System.get_env("MATRIX_PASSWORD")}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

`Matrx.Client` starts the consumer before its single sync loop. Do not combine
`Matrx.Dev.connect/3` and a Client process at the same time. this will fail.

By default, Client and Dev skip message history in the first sync for a local
session, but still process room state and invites. A persisted sync token lets
later restarts receive messages sent while the bot was offline. Set
`initial_history: true` to deliver that first history batch. The low-level
`Matrx.SyncLongPoll` interface retains `initial_history: true` by default.
Resumed syncs request full room state to rebuild the in-memory room cache.

Timeline event IDs are recorded per session before publication, so repeated
syncs do not repeatedly redeliver messages. An undecryptable message may still
be delivered once more when its key arrives. This is not exactly-once handler
execution: a crash between recording an event and completing its handler can
lose that delivery. Handlers needing stronger guarantees should durably queue
and acknowledge their own messages. Sync checkpoints are saved after batch
processing, and held back while room keys are missing.

### Presence

Consumers presence messages through the same callback:

```elixir
def handle_event({:presence_update, presence, ctx}) do
  IO.inspect({presence.user_id, presence.presence, presence.status_msg})
  # The cache is already updated when the handler runs:
  {:ok, latest} = Matrx.Presence.get_cached(ctx.session, presence.user_id)
  IO.inspect(latest)
end
```

Presence is scoped to the syncing session, includes your own user regardless
of `ignore_own`, and is delivered on initial sync even with
`initial_history: false`. Each observation replaces that user's cached value.
`get_cached/2` returns `{:ok, presence}` or `:error` for unknown users, not an
assumed offline status. The in-memory cache survives consumer and sync restarts,
but is cleared on application restart.

```elixir
{:ok, presence} = Matrx.Presence.fetch(session, "@alice:example.org")
:ok = Matrx.Presence.set(session, :online, status_msg: "Ready")
:ok = Matrx.Presence.set(session, :unavailable)
:ok = Matrx.Presence.set(session, :offline, status_msg: "")
```

## Getting Help

If you need help, join my matrix instance and join the bot channel
