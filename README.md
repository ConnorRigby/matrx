# Matrx

Elixir library implementing a basic [Matrix](https://matrix.org/) client. It supports the following:

* End to end encryption, verification and cross signing
* Sending and receiving plaintext and end to end encrypted messages. Text and Media upload is supported
* Room membership: join, leave, kick, ban

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
session = Matrx.Dev.connect("https://matrix.example.com", "username")
children = [
  {Matrx.SyncLongPoll, session: session},
  {Matrx.Consumer, handler: MyBot, session: session}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Getting Help

If you need help, join my matrix instance and join the bot channel
