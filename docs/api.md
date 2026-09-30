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

`run/3` dispatches a list of events and returns `{:ok, state, steps}`, or `{:error, error}` with the failing event's `:index` and the completed `:steps` in `error.details`.

Options for all three:

| option | default | meaning |
| --- | --- | --- |
| `:pipeline` | `Aethrion.Pipeline.default()` | which rules run for which event |
| `:max_depth` | 4 | maximum follow-up generations |
| `:max_events` | larger of 32 and 4 per character | maximum events processed per dispatch |

`Aethrion.dispatch/3`, `Aethrion.step/3`, `Aethrion.run/3`, and `Aethrion.demo_state/0` delegate to these; `Aethrion.new_state/1` delegates to `Aethrion.State.new/1`.

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
| `Event.message_sent(from, to, text, tone: tone, observed_by: [...], at: label)` | someone talks to a character; `tone` is `:warm`, `:neutral`, `:cold`, or `:hostile`; witnesses judge the sender |
| `Event.apology_offered(from, to, reason, at: label)` | someone apologizes |
| `Event.time_tick(now, hours: n)` | simulated time passes |
| `Event.gossip_shared(from, to, memory_id, at: label)` | a character tells another about one of their memories (usually produced by rules) |
| `Event.comfort_offered(from, to, at: label)` | someone comforts a character (usually produced by rules) |
| `Event.time_spent_together(from, to, at: label)` | two characters spend time together (usually produced by rules) |

`Event.to_data/1` and `Event.from_data/1` convert events to and from JSON-friendly maps. `from_data/1` only accepts built-in types, so untrusted input cannot create atoms.

## Outputs

Every output carries `:rule` and `:event_id`.

| type | fields |
| --- | --- |
| `:relationship_changed` | `from`, `to`, `delta`: a map of the applied amounts after clamping, e.g. `%{tension: 8}` |
| `:memory_created` | `memory` |
| `:mood_changed` | `character_id`, `before`, `after` |
| `:bond_changed` | `from`, `to`, `before`, `after` (`:estranged`, `:strained`, `:neutral`, `:friendly`, `:close`) |
| `:proactive_message` | `character_id`, `to`, `reason` (`:jealous`, `:lonely`, `:curious`), `text`, `memory_refs`, `context` |
| `:reply` | `character_id`, `to`, `tone`, `text`, `memory_refs`, `context` |
| `:character_interaction` | `kind` (`:gossip`, `:comfort`, `:together`), `character_id` (who started it), `to`, `text`, `memory_refs`, `context` |

Every expressive output names the speaking character `character_id` and the other party `to`. `text` is deterministic fallback text. `context` is an `Aethrion.Expression.Request` snapshot an LLM adapter can render from. Applications decide how to render, store, or deliver outputs; the runtime performs no side effects.

## Errors

Every public function that can fail returns `{:error, %Aethrion.Error{}}`:

```elixir
%Aethrion.Error{
  code: :unknown_character,
  message: "unknown character: \"nobody\"",
  details: %{field: :to, character_id: "nobody"}
}
```

`code` says what went wrong; `details` says where. Location keys are shared across the library: `:index` (0-based event position), `:branch` (scenario branch), `:line` (1-based journal line), `:path` (position in a JSON document), `:file` (the file, for file errors), and `:field`. `Aethrion.Runtime.run/3` also puts the `:steps` completed before the failure in `details`. `Aethrion.Error.format/1` renders the message with its location, as the mix tasks print it.

| code | meaning |
| --- | --- |
| `:invalid_state` | the state, or state data being loaded, is malformed |
| `:invalid_event` | an event field is missing or has the wrong type or value |
| `:unknown_character` | an id does not name a character in the world |
| `:unavailable_character` | an inactive or blocked character was asked to comfort, gossip, or spend time together |
| `:unsupported_event` | no rules are registered for the event type |
| `:rule_failed` | (RuntimeServer) a rule raised; the event was rejected and state kept |
| `:invalid_tuning` | a tuning override names an unknown rule or parameter, or is not an integer |
| `:invalid_scenario` | a scenario file is malformed |
| `:invalid_journal` | a journal file is malformed |
| `:journal_mismatch` | replaying a journal assigned a different event id than recorded |
| `:journal_changed` | a journal changed on disk while `Journal.compact/2` was compacting it |
| `:journal_failed` | (RuntimeServer) the journal could not be written; the event was rejected and state kept |
| `:journal_enabled` | (RuntimeServer) `put_state/2` was called while journaling |
| `:invalid_snapshot` | a saved snapshot exists but cannot be loaded |
| `:invalid_options` | required options are missing or conflict |
| `:already_exists` | a file that must be new already exists |
| `:not_found` | a file or saved state does not exist |
| `:io_error` | reading or writing a file failed |

Optional fields may be omitted from hand-built event maps: `:at` and `:now` default to `"unspecified"`, `:observed_by` to `[]`, and `:tone` to `:neutral`. When given, `:at` and `:now` must be strings. A journaling runtime server also rejects events that would not come back unchanged from JSON (for example an atom or tuple in a custom field).

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
Aethrion.Tuning.from_data(%{"gift" => %{"importance" => 70}}, pipeline: pipeline)
```

Tuning lives in `state.tuning`, persists with the state, and can be set in a scenario's `"tuning"` block.

## Explainability

```elixir
{:ok, step} = Aethrion.step(state, event)

step.trace
|> Enum.filter(&(Aethrion.Trace.concerns?(&1, "yuna") and &1.kind in [:character, :relationship]))
|> Enum.map(&Aethrion.Trace.describe/1)
#=> ["e1 observation: yuna.jealousy 0 -> 15",
#    "e1 observation: yuna->mina.tension 0 -> 8",
#    "e1 mood: yuna.mood neutral -> jealous"]
```

To explain a single value, with the chain of events that caused each change:

```elixir
{:ok, _state, steps} = Aethrion.run(state, events)

steps
|> Aethrion.Explain.character("yuna", :jealousy)
|> Aethrion.Explain.describe()
#=> ["jealousy 0 -> 15 by observation in e1: user gives mina a flower (seen by yuna)",
#    "jealousy 15 -> 10 by comfort in e4: haru comforts yuna <- yuna confides in haru <- time passes +2h"]
```

`Aethrion.Explain.relationship/4` does the same for `affinity`, `trust`, `tension`, or the derived `bond`; both also accept a trace and event list instead of steps. In the interactive demo: `why yuna jealousy`, `why yuna->haru trust`.

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
   initial_state: Aethrion.Runtime.demo_state(),
   persistence: {Aethrion.Persistence.JsonFile, path: "tmp/garden.json"},
   scheduler: [interval_ms: 60_000, tick_hours: 1],
   expression: [adapter: Aethrion.LLM.OpenAICompatible, timeout: 10_000]}
]

Supervisor.start_link(children, strategy: :one_for_one)

:ok = Aethrion.World.subscribe(:garden)
{:ok, state, outputs, log} = Aethrion.World.dispatch(:garden, event)
Aethrion.World.state(:garden)
Aethrion.World.history(:garden)
Aethrion.World.unsubscribe(:garden)
```

A world supervises a `Task.Supervisor` for rendering, an `Aethrion.RuntimeServer`, and an optional `Aethrion.Scheduler` under `:rest_for_one`. With `:persistence`, a restarted runtime resumes from its last snapshot.

### RuntimeServer

| function | meaning |
| --- | --- |
| `start_link(opts)` | `:initial_state`, `:name`, `:pipeline`, `:max_depth`, `:max_events`, `:history_limit`, `:persistence` or `:journal` (with `:journal_compact_every`), `:expression` |
| `dispatch(server, event)` | same result as `Runtime.dispatch/3` |
| `step(server, event)` | `{:ok, %Aethrion.Step{}}` |
| `get_state(server)`, `put_state(server, state)` | read or replace the state |
| `history(server)` | host events dispatched, oldest first |
| `compact_journal(server)` | restart the journal from the current state |
| `subscribe(server, pid)`, `unsubscribe(server, pid)` | receive messages below |

Subscriber messages:

```elixir
{:aethrion, server_pid, {:dispatched, %Aethrion.Step{}}}
{:aethrion, server_pid, {:expressed, output}}   # when :expression is configured
```

### Scheduler

`Aethrion.Scheduler` emits `time_tick` events into a runtime server every `:interval_ms`, advancing `:tick_hours`. It owns no rules. With `notify: pid`, it sends `{:aethrion, scheduler_pid, {:scheduler_tick, result}}` after each tick.

## Persistence

```elixir
:ok = Aethrion.Persistence.JsonFile.save(state, path: "tmp/aethrion.json")
{:ok, loaded} = Aethrion.Persistence.JsonFile.load(path: "tmp/aethrion.json")
```

`Aethrion.State.to_data/1` writes format version 2. `from_data/1` also reads v0.1 data. For data you did not produce, use `Aethrion.State.parse/2`, which validates shapes, types, and ranges and returns `{:error, %Aethrion.Error{code: :invalid_state}}` with the `:path` of the first problem instead of raising. `JsonFile.load/1` uses it and reports a missing file as `:not_found`. A runtime server whose snapshot exists but cannot be read refuses to start rather than overwrite it. `Aethrion.Persistence.InMemory` is the reference adapter; implement `Aethrion.Persistence` for your own storage.

## Journals

An `Aethrion.Journal` stores a world as its starting state plus every host event, one JSON line each. Replaying rebuilds exactly the same world, so a journal is both a durable log and a reproducible bug report.

```elixir
{Aethrion.World, name: :garden, journal: "tmp/garden.jsonl"}   # append on every dispatch, rebuild on start

{:ok, state, steps} = Aethrion.Journal.replay("tmp/garden.jsonl")
{:ok, scenario_data} = Aethrion.Journal.to_scenario("tmp/garden.jsonl")
```

```bash
mix aethrion.journal tmp/garden.jsonl --report tmp/garden.html
```

Replay fails with an `%Aethrion.Error{code: :journal_mismatch}` (with the event's `:index`) if an event gets a different id than recorded, meaning the journal does not match its starting state.

Replay is exact for the Aethrion version that wrote the journal (its header records it); rules change between versions, so reading a journal from another version logs a warning. Compact a journal with the old version before upgrading to keep the world as it was.

A journal grows with every event and is replayed in full on start. Compaction replaces it with one that starts from the current state; ids continue, and the history is discarded unless archived:

```elixir
Aethrion.World.compact_journal(:garden)                                   # a running world
{Aethrion.World, name: :garden, journal: "tmp/garden.jsonl", journal_compact_every: 1_000}  # automatically
{:ok, state, 1_204} = Aethrion.Journal.compact("tmp/garden.jsonl", archive: "tmp/garden-2026-10.jsonl")
```

```bash
mix aethrion.journal tmp/garden.jsonl --compact --archive tmp/garden-2026-10.jsonl
```
Journals and snapshot persistence are alternatives; a runtime server accepts one or the other, and refuses `put_state/2` while journaling.

## Scenarios and reports

```elixir
{:ok, scenario} = Aethrion.Scenario.load("priv/scenarios/01_the_flower.json")
{:ok, result} = Aethrion.Scenario.run(scenario)
Aethrion.Scenario.passed?(result)
File.write!("report.html", Aethrion.Report.html(result))
```

See [scenarios.md](scenarios.md).

## Mix tasks

The `demo.*` tasks live in `dev/` and run only from a checkout of this repository.

| task | purpose |
| --- | --- |
| `mix demo.drama` | two host events and everything they cascade into |
| `mix demo.branches` | one moment (the crossroads scenario), four branches, compared |
| `mix demo.interactive` | REPL with `say`, `here`, `why`, `context`, `undo`, `--llm`, `--locale ko` |
| `mix aethrion.scenario PATH \| --all` | run scenarios and check expectations |
| `mix aethrion.report PATH \| --all` | render HTML reports; `--out` / `--out-dir`, `--locale ko` |
| `mix aethrion.rules` | print the rule pipeline |
| `mix aethrion.journal PATH` | replay a journal; `--scenario` / `--report` to export, `--compact [--archive FILE]`, `--max-depth` / `--max-events` |
