# Aethrion API

This document describes the public v0.2 alpha API surface. The API may still change before 1.0.

## Runtime

```elixir
Aethrion.Runtime.dispatch(state, event, opts \\ [])
```

Returns:

```elixir
{:ok, next_state, outputs, log}
{:error, %Aethrion.Error{}}
```

Invalid events never change state. `outputs` are structured effects for the host application to handle. `log` is human-readable text.

For the full picture, use `step/3`:

```elixir
{:ok, %Aethrion.Step{} = step} = Aethrion.Runtime.step(state, event)

step.state    # state after the event and every follow-up
step.event    # the host event with its assigned id ("e1", "e2", ...)
step.events   # every processed event, follow-ups carry :cause
step.outputs  # structured outputs, each tagged with :rule and :event_id
step.log      # log lines
step.trace    # [%Aethrion.Trace{}] - every change, by rule, with before/after values
```

`run/3` dispatches a list of events and returns `{:ok, state, steps}` or `{:error, {index, error, steps_so_far}}`.

Options for all three:

| option | default | meaning |
| --- | --- | --- |
| `:pipeline` | `Aethrion.Pipeline.default()` | which rules run for which event |
| `:max_depth` | 4 | maximum follow-up generations |
| `:max_events` | 32 | maximum events processed per dispatch |

`Aethrion.dispatch/3`, `Aethrion.step/3`, `Aethrion.run/3`, `Aethrion.demo_state/0`, and `Aethrion.new_state/1` delegate to these.

## State

```elixir
Aethrion.State.new(
  characters: [%Aethrion.Character{id: "mina", name: "Mina", traits: [:warm]}],
  relationships: [%Aethrion.Relationship{from: "mina", to: "user", affinity: 40}]
)
```

| field | meaning |
| --- | --- |
| `characters` | `%{id => %Aethrion.Character{}}`; each has a `state` (`%Aethrion.CharacterState{}`) |
| `relationships` | `%{{from, to} => %Aethrion.Relationship{}}`, directed |
| `memories` | `[%Aethrion.Memory{}]`, newest first |
| `clock` | simulated hours elapsed |
| `seq` | events processed; used for event ids |
| `cooldowns` | `%{key => clock}` for rate-limited behavior |

`Aethrion.Runtime.demo_state/0` returns the built-in Mina / Yuna / Haru world.

Character state fields: `mood` (derived), `loneliness`, `jealousy`, `joy`, `stress`, `energy` (0..100), `active?`, `blocked?`, `last_active_at`.

Memory fields: `importance`, `strength` (decays with age), `kind` (`:experienced`, `:observed`, `:heard`, `:impression`), `consolidated_into`, `topic` (shared by every memory of the same underlying event), `source` (who told them), `data` (structured facts), `shared_with`, `related_characters`.

## Events

| constructor | meaning |
| --- | --- |
| `Event.gift_received(from, to, item, observed_by: [...], at: label)` | someone gives a character an item |
| `Event.message_sent(from, to, text, tone: tone, at: label)` | someone talks to a character; `tone` is `:warm`, `:neutral`, `:cold`, or `:hostile` |
| `Event.apology_offered(from, to, reason, at: label)` | someone apologizes |
| `Event.time_tick(now, hours: n)` | simulated time passes |
| `Event.gossip_shared(from, to, memory_id, at: label)` | a character tells another about one of their memories (usually produced by rules) |
| `Event.comfort_offered(from, to, at: label)` | someone comforts a character (usually produced by rules) |

`Event.to_data/1` and `Event.from_data/1` convert events to and from JSON-friendly maps. `from_data/1` only accepts built-in types, so untrusted input cannot create atoms.

## Outputs

Every output carries `:rule` and `:event_id`.

| type | fields |
| --- | --- |
| `:relationship_changed` | `from`, `to`, `delta` (applied, after clamping) |
| `:memory_created` | `memory` |
| `:mood_changed` | `character_id`, `from`, `to` |
| `:proactive_message` | `character_id`, `to`, `reason` (`:jealous`, `:lonely`, `:curious`), `text`, `memory_refs`, `context` |
| `:reply` | `character_id`, `to`, `tone`, `text`, `memory_refs`, `context` |
| `:character_interaction` | `kind` (`:gossip`, `:comfort`), `from`, `to`, `text`, `memory_refs`, `context` |

`text` is deterministic fallback text. `context` is an `Aethrion.Expression.Request` snapshot an LLM adapter can render from. Applications decide how to render, store, or deliver outputs; the runtime performs no side effects.

## Errors

```elixir
%Aethrion.Error{
  code: :unknown_character,
  message: "unknown character: \"nobody\"",
  details: %{field: :to, character_id: "nobody"}
}
```

| code | meaning |
| --- | --- |
| `:invalid_state` | the state is not an `Aethrion.State` |
| `:invalid_event` | a field is missing or has the wrong type or value |
| `:unknown_character` | an id does not name a character in the world |
| `:unavailable_character` | an inactive or blocked character was asked to comfort or gossip |
| `:unsupported_event` | no rules are registered for the event type |
| `:rule_failed` | (RuntimeServer only) a rule raised; the event was rejected and state kept |

Optional fields may be omitted from hand-built event maps: `:at` and `:now` default to `"unspecified"`, `:observed_by` to `[]`, and `:tone` to `:neutral`.

## Rules and pipeline

```elixir
pipeline =
  Aethrion.Pipeline.default()
  |> Aethrion.Pipeline.append(:gift_received, MyGame.Rules.Rivalry)
  |> Aethrion.Pipeline.remove(Aethrion.Rules.Autonomy)

Aethrion.dispatch(state, event, pipeline: pipeline)
```

| function | meaning |
| --- | --- |
| `Pipeline.default/0` | built-in rules |
| `Pipeline.append/3`, `prepend/3` | add a rule for an event type (registers new types) |
| `Pipeline.remove/2` | remove a rule everywhere |
| `Pipeline.add_reactive/2` | add a rule that runs after every event |
| `Pipeline.describe/1` | `[{type, [{rule_id, description}]}]` |

See [rules.md](rules.md) for every built-in rule and for writing your own with `use Aethrion.Rule`.

### Tuning

Rule parameters are data. Override them per world:

```elixir
state = Aethrion.Tuning.put(state, :proactive, :cooldown_hours, 8)
Aethrion.Tuning.get(state, Aethrion.Rules.Proactive, :cooldown_hours)  #=> 8
Aethrion.Tuning.describe(state)  #=> [{rule_id, [{key, default, current}]}]
```

Tuning lives in `state.tuning`, persists with the state, and can be set in a scenario's `"tuning"` block.

## Explainability

```elixir
{:ok, step} = Aethrion.step(state, event)

step.trace
|> Enum.filter(&Aethrion.Trace.concerns?(&1, "yuna"))
|> Enum.map(&Aethrion.Trace.describe/1)
#=> ["e1 observation: yuna.jealousy 0 -> 15",
#    "e1 observation: yuna->mina.tension 0 -> 8", ...]
```

## Memory queries

`Aethrion.Memories` answers questions deterministically, without embeddings:

| function | returns |
| --- | --- |
| `for_character(state, id, include_faded: false)` | a character's memories, newest first |
| `recent(state, id, limit)` | the most recent |
| `important(state, id, limit)` | the most important, ties to the newer |
| `about(state, id, other_id)` | memories involving another actor |
| `relevant(state, id, focus: ids, limit: 3)` | ranked by strength + focus bonus + recency |
| `knows_topic?(state, id, topic)` | whether a character knows about an event, even faded |

## Expression and intent

```elixir
outputs = Aethrion.Expression.render(outputs, adapter: Aethrion.LLM.Anthropic)

{:ok, event, meta} = Aethrion.Intent.interpret(state, "sorry about earlier", to: "yuna")
```

See [expression.md](expression.md).

## OTP runtime

### World

```elixir
children = [
  {Aethrion.World,
   name: :garden,
   state: Aethrion.Runtime.demo_state(),
   persistence: {Aethrion.Persistence.JsonFile, path: "tmp/garden.json"},
   scheduler: [interval_ms: 60_000, tick_hours: 1],
   expression: [adapter: Aethrion.LLM.OpenAICompatible, timeout: 10_000]}
]

Supervisor.start_link(children, strategy: :one_for_one)

:ok = Aethrion.World.subscribe(:garden)
{:ok, state, outputs, log} = Aethrion.World.dispatch(:garden, event)
Aethrion.World.state(:garden)
Aethrion.World.history(:garden)
```

A world supervises a `Task.Supervisor` for rendering, an `Aethrion.RuntimeServer`, and an optional `Aethrion.Scheduler` under `:rest_for_one`. With `:persistence`, a restarted runtime resumes from its last snapshot.

### RuntimeServer

| function | meaning |
| --- | --- |
| `start_link(opts)` | `:initial_state`, `:name`, `:pipeline`, `:history_limit`, `:persistence`, `:expression` |
| `dispatch(server, event)` | same result as `Runtime.dispatch/3` |
| `step(server, event)` | `{:ok, %Aethrion.Step{}}` |
| `get_state(server)`, `put_state(server, state)` | read or replace the state |
| `history(server)` | host events dispatched, oldest first |
| `subscribe(server, pid)`, `unsubscribe(server, pid)` | receive messages below |

Subscriber messages:

```elixir
{:aethrion, server_pid, {:dispatched, %Aethrion.Step{}}}
{:aethrion, server_pid, {:expressed, output}}   # when :expression is configured
```

### Scheduler

`Aethrion.Scheduler` emits `time_tick` events into a runtime server every `:interval_ms`, advancing `:tick_hours`. It owns no rules.

## Persistence

```elixir
:ok = Aethrion.Persistence.JsonFile.save(state, path: "tmp/aethrion.json")
{:ok, loaded} = Aethrion.Persistence.JsonFile.load(path: "tmp/aethrion.json")
```

`Aethrion.State.to_data/1` writes format version 2. `from_data/1` also reads v0.1 data. For data you did not produce, use `Aethrion.State.parse/1`, which validates shapes, types, and ranges and returns `{:error, {:invalid_state_data, path, reason}}` instead of raising. `JsonFile.load/1` uses it. A runtime server whose snapshot exists but cannot be read refuses to start rather than overwrite it. `Aethrion.Persistence.InMemory` is the reference adapter; implement `Aethrion.Persistence` for your own storage.

## Scenarios and reports

```elixir
{:ok, scenario} = Aethrion.Scenario.load("priv/scenarios/01_the_flower.json")
{:ok, result} = Aethrion.Scenario.run(scenario)
Aethrion.Scenario.passed?(result)
File.write!("report.html", Aethrion.Report.html(result))
```

See [scenarios.md](scenarios.md).

## Mix tasks

| task | purpose |
| --- | --- |
| `mix demo.drama` | two host events and everything they cascade into |
| `mix demo.branches` | the same setup, ignored vs. apologized |
| `mix demo.interactive` | REPL with `say`, `why`, `context`, `undo`, `--llm` |
| `mix aethrion.scenario PATH \| --all` | run scenarios and check expectations |
| `mix aethrion.report PATH \| --all` | render HTML reports |
| `mix aethrion.rules` | print the rule pipeline |
