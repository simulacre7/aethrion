# Architecture

How Aethrion is put together, for people changing it. For using it, start with the [tutorial](tutorial.md) and the [API reference](api.md).

## Layers

```mermaid
flowchart TB
    subgraph Core["Deterministic core (pure functions over data)"]
        Event["Event\nconstructors, normalize, JSON"] --> Validator
        Validator --> Runtime["Runtime\nstep / dispatch / run"]
        Runtime --> Pipeline
        Pipeline --> Rules["Rules\n(one module per rule)"]
        Rules --> Transition["Transition\ntracked changes"]
        Transition --> State["State\ncharacters, relationships,\nmemories, clock, tuning"]
        Transition --> Trace
        Transition --> Outputs
    end

    subgraph Expression["Expression (optional, text only)"]
        Outputs --> Request["Expression.Request\nread-only snapshot"]
        Request --> Adapter["LLM adapter\nFake / Anthropic / OpenAI-compatible"]
        Intent["Intent\nfree text -> proposed event"] --> Event
    end

    subgraph OTP["OTP runtime (processes around the core)"]
        World --> RuntimeServer
        World --> Scheduler
        World --> TaskSupervisor["Task.Supervisor\n(rendering)"]
        RuntimeServer --> Runtime
        RuntimeServer --> Storage["Persistence snapshot\nor Journal"]
    end

    subgraph Tooling
        Scenario --> Runtime
        Report --> Scenario
        Explain --> Trace
    end
```

The core never performs I/O, reads the wall clock, or uses randomness. Everything that does (files, HTTP, timers, processes) lives in the outer layers and calls into the core.

## Lifecycle of one host event

1. **Normalize.** `Event.normalize/1` fills optional fields (`:at`, `:now`, `:observed_by`, `:tone`).
2. **Validate.** `Validator` checks the type is registered in the pipeline and, for built-in types, every field. Invalid events return `{:error, %Aethrion.Error{}}` and never touch state.
3. **Assign an id.** `state.seq` is incremented; the event becomes `"e<seq>"`.
4. **Run rules.** For the event's type, `Pipeline.rules_for/2` returns the event rules followed by the reactive rules. Each rule receives a `Transition` and returns it. Rules change state only through `Transition` helpers, each of which clamps, records a `Trace` entry tagged with the rule id and event id, and where it applies emits an output and a log line.
5. **Collect follow-ups.** Rules may `enqueue/2` events (a confidence, comfort, an outing). They carry `:cause` and go through steps 1-4 themselves, breadth-first, until the queue is empty or a limit is hit (`max_depth`, `max_events`). Dropped follow-ups are logged and traced.
6. **Return a `Step`**: the final state, every processed event, outputs, log, and trace.

## Determinism

The same state, event, pipeline, and limits always produce the same `Step`. This is what makes scenarios, journals, branches, and property tests possible. To keep it:

- Iterate characters with `State.sorted_characters/1`; never rely on map order.
- Break ties explicitly (by id) whenever sorting by a score.
- Derive time from `state.clock`, never the system clock. Quantities that accumulate over time (memory decay, tension easing) are computed from absolute clock values or day boundaries so they do not depend on how time was split into ticks.
- Keep rule numbers in `params` and read them with `Transition.param/2`, so a world's tuning is part of its state.

`mix test` includes property tests that replay random event sequences and check that results are identical, bounded, persistable, journal-replayable, and recordable as passing scenarios.

## State

`Aethrion.State` is plain data:

| field | notes |
| --- | --- |
| `characters` | `%{id => %Character{}}`; each has a `%CharacterState{}` with bounded numbers and a derived `mood` |
| `relationships` | `%{{from, to} => %Relationship{}}`, directed; missing pairs read as all zeros |
| `memories` | newest first; each has a `topic` linking everyone's memory of one event |
| `clock`, `seq` | simulated hours; processed event count |
| `cooldowns` | `%{key => clock}` for rate-limited behaviors |
| `tuning` | rule parameter overrides |

`State.to_data/1` and `State.parse/2` convert to and from JSON-friendly data. Parsing validates untrusted input and never creates atoms.

## Memory

Memories are created by rules (`remember/3`), decay with age (`MemoryDecay`), fold into impressions when faded (`Consolidation`), and are eventually forgotten. Retrieval (`Aethrion.Memories`) is a deterministic score over strength, focus, and recency: no embeddings. Memory work runs on every tick, so rules that touch memories use single passes (`Transition.map_memories/4`, `drop_memories/2`) and per-application indexes rather than per-character rescans.

## The expression boundary

Rules attach deterministic fallback text and an `Expression.Request` snapshot to every expressive output. `Expression.render/2` passes only that snapshot to an adapter and only replaces text. `Intent.interpret/3` lets an adapter choose from a closed set of proposals; the result is an ordinary event that still goes through validation and rules. Adapters never see `State`, and the tests assert it.

## OTP

`Aethrion.World` supervises, with `:rest_for_one`:

1. a `Task.Supervisor` for rendering,
2. an `Aethrion.RuntimeServer` that owns the state, subscribers, history, and storage,
3. an optional `Aethrion.Scheduler` that dispatches `time_tick` events.

The server calls `Runtime.step/3`, writes the journal (if any) before committing the new state, saves snapshots (if any), broadcasts to subscribers, and starts rendering tasks with timeouts. A crashing rule rejects the event; a crashing or slow adapter produces fallback text; a crashing server restarts from its snapshot or journal.

## Adding things

| to add | touch |
| --- | --- |
| a rule | a module with `use Aethrion.Rule`; register it in `Pipeline.default/0` (or a host pipeline); document it in `docs/rules.md`; add a scenario |
| an event type | a constructor, `describe/2`, and `from_data` builder in `Event`; validation in `Validator`; the scenario schema; docs |
| an output type | a constructor in `Output`; `Display` and `Report` rendering; docs |
| a template line | `Expression.Templates` and `Expression.Templates.Ko` |
| an LLM provider | a module implementing `Aethrion.LLM.Adapter`, using `Expression.Prompt` and `LLM.HTTP` |
