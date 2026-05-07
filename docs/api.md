# Aethrion API

This document describes the public v0.1 alpha API surface.

## Runtime

```elixir
Aethrion.Runtime.dispatch(state, event)
```

Returns:

```elixir
{:ok, next_state, outputs, log}
{:error, %Aethrion.Error{}}
```

`outputs` are structured effects for the host application to handle. `log` is human-readable demo/debug text.

## State

```elixir
Aethrion.State.new(
  characters: characters,
  relationships: relationships
)
```

`Aethrion.Runtime.demo_state/0` returns the built-in Mina/Yuna/Haru scenario state.

## Events

Supported alpha events:

```elixir
Aethrion.Event.gift_received("user", "mina", "flower",
  observed_by: ["yuna"],
  at: "demo:t1"
)
```

```elixir
Aethrion.Event.time_tick("demo:t2", hours: 2)
```

## Outputs

Supported alpha outputs:

- `:relationship_changed`
- `:memory_created`
- `:proactive_message`

Applications decide how to render, store, or deliver outputs. The runtime itself does not perform external side effects.

## Errors

Invalid inputs return `%Aethrion.Error{}`:

```elixir
%Aethrion.Error{
  code: :unknown_character,
  message: "unknown character: \"nobody\"",
  details: %{field: :to, character_id: "nobody"}
}
```

Known error codes:

- `:invalid_state`
- `:invalid_event`
- `:unknown_character`
- `:unsupported_event`

## Persistence

Aethrion includes a persistence behaviour and two alpha adapters:

- `Aethrion.Persistence.InMemory`
- `Aethrion.Persistence.JsonFile`

Example:

```elixir
state = Aethrion.Runtime.demo_state()
:ok = Aethrion.Persistence.JsonFile.save(state, path: "tmp/aethrion.json")
{:ok, loaded} = Aethrion.Persistence.JsonFile.load(path: "tmp/aethrion.json")
```
