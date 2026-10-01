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
  characters: [%Aethrion.Character{id: "mina", name: "Mina", traits: [:sensitive]}],
  relationships: [%Aethrion.Relationship{from: "mina", to: "user", affinity: 40}]
)
```

| field | meaning |
| --- | --- |
| `characters` | `%{id => %Aethrion.Character{}}`; each has a `state` (`%Aethrion.CharacterState{}`) |
| `relationships` | `%{{from, to} => %Aethrion.Relationship{}}`, directed; `bond` is the last bond announced (read the current one with `Aethrion.Rules.Bond.derive/2`) |
| `memories` | `[%Aethrion.Memory{}]`, newest first |
| `clock` | simulated hours elapsed |
| `seq` | events processed; used for event ids |
| `cooldowns` | `%{key => clock}` for rate-limited behavior |
| `people` | `%{id => display name}` for players and other actors who are not characters (`State.new(people: ...)`, saved as `"people"`) |

`Aethrion.Runtime.demo_state/0` returns the built-in Mina / Yuna / Haru world.

Character state fields: `mood` (derived), `loneliness`, `jealousy`, `joy`, `stress`, `energy` (0..100), `active?`, `blocked?`, `last_active_at`.

Memory fields: `importance`, `strength` (decays with age), `kind` (`:experienced`, `:observed`, `:heard`, `:impression`), `consolidated_into`, `topic` (shared by every memory of the same underlying event), `source` (who told them), `data` (structured facts), `shared_with`, `related_characters`.

## Events

| constructor | meaning |
| --- | --- |
| `Event.gift_received(from, to, item, observed_by: [...], at: label)` | someone gives a character an item |
| `Event.apology_offered(from, to, reason, observed_by: [...], at: label)` | someone apologizes to a character; witnesses judge it |
| `Event.message_sent(from, to, text, tone: tone, observed_by: [...], at: label)` | someone talks to a character; `tone` is `:warm`, `:neutral`, `:cold`, or `:hostile`; witnesses judge the sender |
| `Event.time_tick(now, hours: n)` | simulated time passes |
| `Event.gossip_shared(from, to, memory_id, at: label)` | a character tells another about one of their memories (usually produced by rules) |
| `Event.comfort_offered(from, to, at: label)` | someone comforts a character (usually produced by rules) |
| `Event.time_spent_together(from, to, at: label)` | two characters spend time together (usually produced by rules) |

`Event.to_data/1` and `Event.from_data/2` convert events to and from JSON-friendly maps. `from_data/2` accepts built-in types, plus custom types registered in the `pipeline:` you pass, so untrusted input cannot create atoms.

## Outputs

Every output carries `:rule` and `:event_id`.

| type | fields |
| --- | --- |
| `:relationship_changed` | `from`, `to`, `delta`: a map of the applied amounts after clamping, e.g. `%{tension: 8}` |
| `:memory_created` | `memory` |
| `:mood_changed` | `character_id`, `before`, `after` |
| `:bond_changed` | `from`, `to`, `before`, `after` (`:estranged`, `:strained`, `:neutral`, `:friendly`, `:close`) |
| `:proactive_message` | `character_id`, `to`, `reason` (`:jealous`, `:lonely`, `:curious`, `:protective`), `text`, `memory_refs`, `context` |
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
| `:world_not_running` | (World) `dispatch/2` or `step/2` named a world that is not running |
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

## Digest

`Aethrion.Digest.of(outputs, state, opts)` turns a stretch of outputs into short lines for people: scenes between characters, messages characters sent, and new beliefs in order, then net bond and mood changes (a bond that went down and back up again is left out). `locale: :ko` gives Korean lines; `you:` names the person addressed as "you" (default `"user"`), and `only_you: true` leaves out what concerns other people (messages to them, bonds toward them, beliefs and gossip about them), for a player's own digest in a shared world. Scenes are told to the reader; quoted lines stay said to whoever heard them. Players are named by the state's `people` display names. Each item is `%{kind, event_id, text}`. In the interactive demo, `digest` shows what changed since the last one.

```elixir
Aethrion.Digest.of(outputs_since_last_visit, state)
#=> [%{kind: :scene, event_id: "e7", text: "Haru and Yuna spend a quiet afternoon together."},
#    %{kind: :bond, event_id: "e5", text: "Yuna cooled toward you (now neutral)."},
#    %{kind: :mood, event_id: "e6", text: "Haru, Mina, and Yuna are lonely."}]
```

New beliefs read like "Mina remembers you being warm twice." or "Haru knows how you treat others: hostile to Mina and Yuna, twice."

## Memory queries

`Aethrion.Memories` answers questions deterministically, without embeddings:

| function | returns |
| --- | --- |
| `for_character(state, id, include_faded: false)` | a character's memories, newest first |
| `recent(state, id, limit)` | the most recent |
| `important(state, id, limit)` | the most important, ties to the newer |
| `about(state, id, other_id)` | memories involving another actor |
| `relevant(state, id, focus: ids, limit: 3)` | ranked by strength + focus bonus + recency |
| `knows_topic?(state, id, topic)` | whether a character knows about an event, even faded or folded into an impression |

What characters have come to believe, and how relationships read:

```elixir
Aethrion.Rules.Consolidation.counts(state, "mina", "user")
#=> %{{"impression", "warm"} => 3, {"reputation", "hostile"} => 2}

Aethrion.Rules.Bond.derive(Aethrion.State.get_relationship(state, "mina", "user"), state)
#=> :friendly   # one of Aethrion.Rules.Bond.bonds(), worst to closest
```

A bond holds until the numbers move 5 points past the threshold that would change it, so `derive/2` reads the relationship's recorded `bond` as well as its numbers.

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
Aethrion.World.get_state(:garden)
Aethrion.World.history(:garden)
Aethrion.World.unsubscribe(:garden)
```

A world supervises a `:pg` scope for its subscribers, a `Task.Supervisor` for rendering, an `Aethrion.RuntimeServer`, and an optional `Aethrion.Scheduler` under `:rest_for_one`. With `:persistence` or `:journal`, a restarted runtime resumes from its last snapshot or journal.

### RuntimeServer

| function | meaning |
| --- | --- |
| `start_link(opts)` | `:initial_state`, `:name`, `:pipeline`, `:max_depth`, `:max_events`, `:history_limit`, `:persistence` or `:journal` (with `:journal_compact_every`), `:expression`, `:subscribers` (a `:pg` scope, or `{scope, group}`), `:tag` |
| `dispatch(server, event)` | same result as `Runtime.dispatch/3` |
| `step(server, event)` | `{:ok, %Aethrion.Step{}}` |
| `get_state(server)`, `put_state(server, state)` | read or replace the state |
| `history(server)` | host events dispatched, oldest first |
| `compact_journal(server)` | restart the journal from the current state |
| `subscribe(server, pid)`, `unsubscribe(server, pid)` | receive messages below |

Subscriber messages:

```elixir
{:aethrion, tag, {:dispatched, %Aethrion.Step{}}}
{:aethrion, tag, {:expressed, output}}   # when :expression is configured
```

`tag` is the world's name for an `Aethrion.World` (so one process can listen to many worlds), and the server's pid for a bare `RuntimeServer` unless it was given `tag:`. A World keeps its subscribers outside the runtime server, so they stay subscribed when it restarts.

### Many worlds

`Aethrion.Worlds` runs one world per key (any term, never made an atom) for chat apps and game servers:

```elixir
children = [
  {Aethrion.Worlds,
   name: MyApp.Worlds,
   idle_after: :timer.minutes(30),     # stop unused worlds; needs :journal or :persistence
   world: fn user_id ->                # options of Aethrion.World, except :name
     [initial_state: MyApp.Cast.state(), journal: "data/worlds/#{Aethrion.Worlds.file_name(user_id)}.jsonl"]
   end}
]

{:ok, state, outputs, log} = Aethrion.Worlds.dispatch(MyApp.Worlds, "user-42", event)
{:ok, step} = Aethrion.Worlds.step(MyApp.Worlds, "user-42", event)
{:ok, state} = Aethrion.Worlds.get_state(MyApp.Worlds, "user-42")
:ok = Aethrion.Worlds.subscribe(MyApp.Worlds, "user-42")   # {:aethrion, {MyApp.Worlds, "user-42"}, payload}
Aethrion.Worlds.running(MyApp.Worlds)                       # keys of running worlds
:ok = Aethrion.Worlds.stop(MyApp.Worlds, "user-42")
```

A running world with the demo cast and a short chat takes about 120 KB and three processes; 500 such worlds handled 5,000 messages in about 2.5 seconds on a laptop, so memory, not CPU, is what `:idle_after` saves. Worlds start on first use; `peek_state/2` reads one without starting it if it has never been used. Name files after keys with `Aethrion.Worlds.file_name/1`, which keeps every key distinct (also on case-insensitive file systems) and inside the directory. Subscriptions belong to the key, so they last while its world stops and starts. A world's options are checked when it starts; unknown keys and `:idle_after` without storage are `:invalid_options` errors.

### Conversations

Every step records what people said to characters (messages, gifts, apologies), what characters said back (replies, proactive messages), and what a person and a character did to each other in a fight (`deed` turns such as "heals user for 8", which a model sees as "(in the fight: ...)"): the last 24 turns per pair, in `state.conversations`, saved and journaled with the state. No rule reads them.

```elixir
Aethrion.Conversation.recent(state, "mina", "user")
# [%{from: "user", to: "mina", text: "...", kind: :message, tone: :warm, event_id: "e3", at: 12}, ...]
```

Replies and proactive messages carry the last 12 turns in their request (`Request.conversation`). A server rendering with a model replaces a character's draft with what the model said (`Aethrion.Conversation.put_rendered/2`) and journals it, so replay holds the same words. Hosts rendering on their own (`Aethrion.Expression.render/2`) can call `put_rendered/2` with the rendered outputs.

### Scheduler

`Aethrion.Scheduler` emits `time_tick` events into a runtime server every `:interval_ms`, advancing `:tick_hours`. It owns no rules. With `notify: pid`, it sends `{:aethrion, scheduler_pid, {:scheduler_tick, result}}` after each tick.

## Stats, stories, and fights

Every actor (character or player) can have free-form numeric `stats` in the state (`%{"mina" => %{"charm" => 12}, "user" => %{"hp" => 30}}`). Rules change them with `Aethrion.Transition.adjust_stat/5` (traced), and `Aethrion.Explain.stat/3` says why one is what it is.

A world's `story` (`Aethrion.Story`) holds `activities`, ordered `endings` with conditions, a `deadline`, and `decide_when`. `Event.activity("mina", "study")` applies an activity; the ending is decided once, at the deadline or when a `decide_when` condition holds, as an `:ending_reached` output (`ending`, `title`, `description`, `because`).

```elixir
Aethrion.Story.ending(state)     # {:ok, %{id, title, description, because}} | :none, if decided now
Aethrion.Story.progress(state)   # [%{id, title, met, total, closeness, missing}]
Aethrion.Rules.Ending.reached(state)  # the ending decided, or nil
```

Conditions: `{"stat": [actor, name]}`, `{"character": id, "field": f}`, `{"relationship": [from, to], "field": f}` with `at_least`/`at_most`/`equals`; `{"bond": [from, to], "is" | "at_least" | "at_most": bond}`; `{"memories": {"character": id, ...data filters}}` counts; `{"clock": true}`; `{"any": [...]}`; `{"not": c}`.

Fights (`Aethrion.Combat`, `Aethrion.Rules.Combat`) are between actors with an `"hp"` stat (`"max_hp"`, `"attack"`, `"defense"`, `"speed"`, `"heal"` optional): `Event.attack/3`, `defend/2`, `heal/3`, `flee/3`. Outputs are `:combat` maps (`kind`: `:hit`, `:critical`, `:defeated`, `:guarded`, `:healed`, `:fled`, `:caught`, `:holds_back`; `character_id`, `to`, `subject`, `amount`, `hp`, `max_hp`, `text`). `Combat.describe(output, state, :ko)` tells one in Korean; `Combat.action(state, from, target, text)` reads a player's words (a nil target means `Combat.foe/1`, the first enemy standing, and an attack is watched by `Combat.party/1`). Damage rolls come from who acts on whom and both fighters' hp, not from the event id, so a fight replays exactly. Heals need a healer's `"heal"` stat or an item they hold (a potion uses one of their `"potions"`, a bandage one of `"bandages"`), a standing healer, and a hurt, standing target; asking a companion to heal ("리아, 치료해 줘") is the asker's turn, and a companion below `party_trust` refuses; one shields only someone on one's own side and flees only from an enemy; enemies go for someone below 40% hp, else take turns between the player and the companions; a character at 0 hp neither talks, listens, nor reaches out; once the story's ending is decided (`decide_when`), combat events are rejected.

## HTTP API

`Aethrion.API` serves an `Aethrion.Worlds` as JSON over HTTP (Erlang's built-in `:httpd`), for engines and backends in any language. `mix aethrion.serve` runs both from a cast file.

```elixir
{Aethrion.API, worlds: MyApp.Worlds, port: 4848, token: System.fetch_env!("AETHRION_TOKEN")}
```

| method | path | body / query | returns |
| --- | --- | --- | --- |
| `POST` | `/worlds/{key}/say` | `{"to", "text", "from"?, "observed_by"?}` | the step: `event_id`, `lines`, `outputs`, `interpreted` |
| `POST` | `/worlds/{key}/events` | an event as in a scenario (`{"type": "gift_received", ...}`) | the step |
| `POST` | `/worlds/{key}/chat` | `{"to", "text", "from"?, "observed_by"?}`: one chat line, read by `Aethrion.Chat` as a fight move (while an enemy stands), a story activity the player suggests (the story's `phrases`, or the activity's name with "하자/할까/let's"), a gift handed over, or talk (`Aethrion.Intent`); `interpreted.as` is `combat`, `activity`, `gift`, or `talk` | the step |
| `POST` | `/worlds/{key}/act` | `{"text", "to"?, "from"?}`: a combat action in words, aimed at whoever the words name (an enemy for a blow), else `to`, else the first enemy standing; `400 unclear_action` when the words do not say what happens | the step |
| `GET` | `/worlds/{key}/story` | | `{"reached": ending \| null, "endings": progress}` |
| `GET` | `/worlds/{key}/conversation` | `character` (omit for every character), `person` (default `user`), `after` (an event id) | `{"turns": [...]}`, oldest first |
| `GET` | `/worlds/{key}/characters` | `person` (default `user`) | `{"characters": [{id, name, profile, mood, toward: {id, bond, affinity, trust, tension}}]}` |
| `GET` | `/worlds/{key}/state` | | `State.to_data/1` |
| `GET` | `/health` | | `{"ok": true}` (no token needed) |
| `GET` | `/` | | a chat page for trying worlds in a browser |

`lines` are what characters said or did in the step: `{type, event_id, character_id, to, text, rendered, reason | kind | tone}`; `rendered` is true when a model phrased the line (not the built-in templates) (a reply's `tone` is what it answers: a message tone, `gift`, or `apology`). `last_event_id` is the last event the step processed, cascades included: poll `conversation?after=` from it so nothing comes twice. Reads (`state`, `characters`, `conversation`) of a world never used do not start it or write files. When the world renders with a model, the response waits (up to `:render_timeout`, default 15 s) for the model's lines; `rendered: false` means the deterministic text. Errors are `{"error": {"code", "message"}}` with 400 (bad request, unknown character, invalid event, `text_too_long`), 401, 404, 405, 413 (`body_too_large`), or 503 (a world could not start or store; the reason goes to the server's log, not the client).

Options: `:worlds`, `:port` (0 for a free one; `Aethrion.API.port/1`), `:bind` (default `"127.0.0.1"`), `:token`, `:intent` (adapter for `say`, default the fake adapter), `:render_timeout`, `:max_body` (bytes), `:max_text` (characters of `say` text, default 2,000). World keys are 1-128 characters of letters, digits, and `_ - . : @`, so they are safe in file names.

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

# Without a server: create, append processed events (with their ids), read.
:ok = Aethrion.Journal.create("tmp/solo.jsonl", state)
{:ok, step} = Aethrion.step(state, event)
:ok = Aethrion.Journal.append("tmp/solo.jsonl", step.event)
{:ok, starting_state, events} = Aethrion.Journal.read("tmp/solo.jsonl")
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
Journals and snapshot persistence are alternatives; a runtime server accepts one or the other. `put_state/2` on a journaling server starts the journal over from the new state, and a state whose tuning the pipeline cannot hold is refused.

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
| `mix aethrion.report PATH \| --all` | render HTML reports (`Aethrion.Report.html(result, locale: :ko)` from code); `--out` / `--out-dir`, `--locale ko` for a Korean report |
| `mix aethrion.rules` | print the rule pipeline |
| `mix aethrion.serve` | the HTTP API over a world per key: `--cast FILE`, `--data DIR`, `--port`, `--bind`, `--token` (or `AETHRION_TOKEN`), `--llm anthropic\|openai`, `--locale ko`, `--idle MINUTES`, `--tick-every SECONDS` (an hour passes in each running world that often) |
| `mix aethrion.journal PATH` | replay a journal; `--scenario` / `--report` to export, `--compact [--archive FILE]`, `--digest [--locale ko]`, `--max-depth` / `--max-events` |
