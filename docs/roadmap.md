# Aethrion Roadmap

This roadmap starts from the current v0 proof of concept and describes the next practical steps toward a usable open-source runtime.

## Current State

Aethrion v0.2 alpha runs this loop:

```txt
event -> validate -> rule pipeline -> follow-up events (cascade)
      -> updated state + structured outputs + trace
      -> optional LLM expression, outside the authoritative path
```

Implemented in v0.2:

- rule behaviour, explicit pipeline, and traced transitions (every change explained by rule and event)
- cascading follow-up events with depth and count limits
- character-to-character behavior: observation, confiding, rumor, empathy, comfort, companionship
- tone-aware messages and replies; simulated clock, cooldowns, derived moods, joy and stress
- memory kinds, topics, sources, age-based decay, deterministic retrieval, consolidation into impressions that change how later messages land
- reputation: witnesses and hearsay judge how someone treats others, and secondhand memories fold into reputation impressions
- derived relationship bonds with announced changes
- expression snapshots, LLM adapter behaviour, Anthropic and OpenAI-compatible adapters, English and Korean templates
- intent interpretation limited to a closed set of proposals
- supervised worlds with subscriptions, history, snapshot recovery, journals with compaction, and async rendering
- data-first scenario files with expectations, HTML reports, and a richer interactive CLI
- rule parameters as data (`Aethrion.Tuning`), per world, persisted, and settable from scenarios
- property-based invariant tests

Not implemented yet:

- per-character actor runtime (deliberately deferred, see Phase 4)
- package publishing

Known limitations in v0.2:

- Templates exist in English and Korean; other languages need a model adapter or new templates.

## Phase 1: v0.1 Library Foundation

Goal: turn the PoC into a small but coherent library surface.

TODO:

- [x] Define the public API around `Aethrion.Runtime.dispatch/2`.
- [x] Add explicit `Aethrion.State.new/1` or scenario builders instead of relying only on demo state.
- [x] Normalize event and output shapes.
- [x] Add validation for unknown characters and unsupported events.
- [x] Return structured errors instead of relying on crashes for normal invalid input.
- [x] Document the supported v0 event types.
- [x] Document the supported v0 output types.
- [x] Add examples for embedding Aethrion in another Elixir app.

Success criteria:

- A developer can create a state, dispatch events, inspect outputs, and understand expected data shapes from docs alone.
- Invalid inputs fail predictably.
- Tests describe the intended public behavior.

## Phase 2: Better Demo And Developer Experience

Goal: make the core idea easy to understand in under 15 minutes.

TODO:

- [x] Add `mix demo.interactive`.
- [x] Support simple CLI commands such as `gift`, `tick`, `status`, and `memories`.
- [x] Print relationship and character state summaries after each command.
- [x] Add a richer scripted scenario with at least two social branches.
- [x] Add a README section that shows the full demo output.
- [x] Add small architecture diagrams using plain Markdown or Mermaid.

Success criteria:

- The demo clearly shows social behavior emerging from deterministic rules.
- Users can experiment without reading the code first.

## Phase 3: Persistence

Goal: make runtime state durable without changing the simulation model.

TODO:

- [x] Define a persistence behaviour.
- [x] Add an in-memory adapter as the reference implementation.
- [x] Add JSON file persistence for local experiments.
- [x] Add serialization tests for characters, relationships, memories, and emitted outputs.
- [x] Keep persistence separate from rule logic.

Success criteria:

- A scenario can stop, reload, and continue with the same state.
- Persistence does not make the runtime dependent on a specific database.

## Phase 4: Process Runtime

Goal: start using Elixir/BEAM strengths where they actually help.

Design direction: keep the simulation model data-first. Characters, relationships, memories, and rules should remain plain data advanced by deterministic functions. Use processes to model runtime behavior such as sessions, schedulers, external calls, persistence boundaries, and supervision. Do not default to "one character = one process" unless a concrete runtime boundary proves it is useful.

TODO:

- [x] Introduce a supervised runtime process.
- [x] Add a scheduler process that emits `time_tick` events.
- [x] Keep character, relationship, memory, and rule state as data by default.
- [x] Use processes for runtime behavior, not as the primary simulation model.
- [ ] Explore character or relationship processes only if a concrete runtime boundary requires them.
- [x] Add crash/restart tests for supervised runtime components.
- [x] Keep deterministic rule functions testable without processes.
- [x] Document tradeoffs around process message passing before adding finer-grained actor processes (see [architecture.md](architecture.md#process-boundaries-and-their-tradeoffs)).
- [x] Run expression rendering in supervised tasks with timeouts, isolated from the runtime.
- [x] Restore runtime state from snapshots after a supervised restart.
- [x] Add subscriptions and bounded event history to the runtime server.
- [x] Add `Aethrion.World` to supervise a runtime, scheduler, and rendering tasks together.

Success criteria:

- Long-lived runtime components can run under supervision.
- The pure simulation core remains testable without a running process tree.
- The runtime does not introduce per-character process bottlenecks without measured need.

## Phase 5: LLM Adapter Layer

Goal: add real expression providers without giving them authority over state.

TODO:

- [x] Define an LLM adapter behaviour.
- [x] Keep `FakeAdapter` as the default for tests.
- [x] Add an OpenAI-compatible adapter.
- [x] Add an Anthropic Messages API adapter.
- [x] Ensure LLM outputs are text/expression only.
- [x] Add tests proving LLM adapters cannot directly mutate simulation state.
- [x] Let models propose intents from free text, limited to a closed set and validated like host events.

Success criteria:

- Real LLM output can make dialogue more natural.
- Removing the LLM adapter does not break deterministic simulation.

## Phase 6: Memory And Social Context

Goal: make memories useful without overbuilding retrieval too early.

TODO:

- [x] Add recent memory queries.
- [x] Add important memory queries.
- [x] Add memory decay rules.
- [x] Add memory consolidation (faded experiences fold into lasting impressions).
- [x] Add relationship-aware context selection.
- [x] Let knowledge spread between characters as secondhand memories.
- [x] Avoid vector search until simple memory retrieval is insufficient.

Success criteria:

- Proactive outputs can reference relevant past events.
- Memory behavior remains explainable and testable.

## Phase 6.5: Rule Organization

Goal: keep deterministic rules explicit and manageable as event types grow.

TODO:

- [x] Introduce a small rule behaviour before considering a generic DSL.
- [x] Add a rule pipeline that makes event-to-rule mapping visible.
- [x] Keep rule ordering, outputs, and logs explicit.
- [x] Add tests for rule ordering and non-mutation on invalid events.
- [x] Record a trace entry for every change so each transition is explainable.
- [x] Move rule parameters (thresholds, deltas) into data a host can tune.
- [x] Defer a DSL until repeated rule patterns are proven.

Success criteria:

- New event rules can be added without bloating `Aethrion.Runtime.dispatch/2`.
- Rule modules remain deterministic and easy to test in isolation.
- The runtime can explain which rules produced each state transition.

## Phase 7: Packaging And Community Readiness

Goal: make the project approachable as an early open-source runtime.

TODO:

- [x] Add license.
- [x] Add contribution guide.
- [x] Add code of conduct if the project becomes public-facing.
- [x] Add CI for formatting and tests.
- [x] Add Hex package metadata before publishing.
- [ ] Publish to Hex when the API is stable enough.
- [x] Add examples directory.
- [x] Add issue templates for bugs, ideas, and demo scenarios.

Success criteria:

- New contributors can run tests and demos quickly.
- The project communicates what is stable and what is experimental.

## Phase 8: Scenarios And Tooling

Goal: make social behavior reviewable by people who do not read Elixir.

TODO:

- [x] Define a JSON scenario format with a world, events, and expectations.
- [x] Run bundled scenarios as tests.
- [x] Render scenarios as self-contained HTML reports.
- [x] Add `why`, `context`, `timeline`, and `undo` to the interactive CLI.
- [x] Compare branches of the same world side by side (scenario branches and report comparison).
- [x] Record interactive sessions as scenario files.

## Phase 9: Social Depth

Goal: make how the user treats one character matter to the others, and let relationships read like relationships.

TODO:

- [x] Witnesses for messages and apologies; judgement by those who care about the receiver, at half strength from hearsay.
- [x] Reputation impressions from faded secondhand memories, counted once per event and weighed below firsthand history.
- [x] Characters speak up to someone who was hostile to a friend.
- [x] Bonds with announced, explainable changes that settle instead of flickering; bonds color replies.
- [x] Characters notice how long it has been since a person last talked to them.
- [x] Journals that stay fast to start (compaction) and warn when replayed by another version.

Success criteria:

- A harsh word in front of a friend changes more than one relationship, and every effect can be explained.
- Long-running worlds stay bounded in memory, cooldowns, and journal size.

## Near-Term Priority

Recommended next tasks:

1. Publish to Hex once the event and output shapes settle.
2. Index memories per character: queries scan every memory, which is fine for hundreds of characters but dominates ticks past about 10,000 memories.
3. Try the Anthropic and OpenAI-compatible adapters against real providers (so far they are tested against a local stub server).
4. Offer a way to migrate a journal across versions instead of only warning.
5. Explore per-character processes only if a concrete runtime need appears.

Phoenix, vector databases, and distributed BEAM remain out of scope until the core runtime interface is stable.
