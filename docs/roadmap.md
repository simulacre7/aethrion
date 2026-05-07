# Aethrion Roadmap

This roadmap starts from the current v0 proof of concept and describes the next practical steps toward a usable open-source runtime.

## Current State

Aethrion currently proves the core loop:

```txt
event -> deterministic rules -> updated in-memory state -> structured outputs
```

Implemented:

- Elixir Mix library project
- English and Korean README
- core domain structs
- in-memory runtime state
- `Aethrion.Runtime.dispatch/2`
- deterministic gift, jealousy, and loneliness rules
- fake LLM adapter
- `mix demo.drama`
- ExUnit scenario and invariant tests

Not implemented yet:

- stable public API
- persistence adapters
- actor/process runtime
- scheduler process
- interactive CLI
- real LLM adapters
- memory retrieval or summarization
- package publishing

## Phase 1: v0.1 Library Foundation

Goal: turn the PoC into a small but coherent library surface.

TODO:

- [ ] Define the public API around `Aethrion.Runtime.dispatch/2`.
- [ ] Add explicit `Aethrion.State.new/1` or scenario builders instead of relying only on demo state.
- [ ] Normalize event and output shapes.
- [ ] Add validation for unknown characters and unsupported events.
- [ ] Return structured errors instead of relying on crashes for normal invalid input.
- [ ] Document the supported v0 event types.
- [ ] Document the supported v0 output types.
- [ ] Add examples for embedding Aethrion in another Elixir app.

Success criteria:

- A developer can create a state, dispatch events, inspect outputs, and understand expected data shapes from docs alone.
- Invalid inputs fail predictably.
- Tests describe the intended public behavior.

## Phase 2: Better Demo And Developer Experience

Goal: make the core idea easy to understand in under 15 minutes.

TODO:

- [ ] Add `mix demo.interactive`.
- [ ] Support simple CLI commands such as `gift`, `tick`, `status`, and `memories`.
- [ ] Print relationship and character state summaries after each command.
- [ ] Add a richer scripted scenario with at least two social branches.
- [ ] Add a README section that shows the full demo output.
- [ ] Add small architecture diagrams using plain Markdown or Mermaid.

Success criteria:

- The demo clearly shows drama emerging from state transitions.
- Users can experiment without reading the code first.

## Phase 3: Persistence

Goal: make runtime state durable without changing the simulation model.

TODO:

- [ ] Define a persistence behaviour.
- [ ] Add an in-memory adapter as the reference implementation.
- [ ] Add JSON file persistence for local experiments.
- [ ] Add serialization tests for characters, relationships, memories, and emitted outputs.
- [ ] Keep persistence separate from rule logic.

Success criteria:

- A scenario can stop, reload, and continue with the same state.
- Persistence does not make the runtime dependent on a specific database.

## Phase 4: Process Runtime

Goal: start using Elixir/BEAM strengths where they actually help.

TODO:

- [ ] Introduce a supervised runtime process.
- [ ] Add a scheduler process that emits `time_tick` events.
- [ ] Explore character or relationship processes only after the library API is stable.
- [ ] Add crash/restart tests for supervised runtime components.
- [ ] Keep pure deterministic rule functions testable without processes.

Success criteria:

- Long-lived runtime components can run under supervision.
- The pure simulation core remains testable without a running process tree.

## Phase 5: LLM Adapter Layer

Goal: add real expression providers without giving them authority over state.

TODO:

- [ ] Define an LLM adapter behaviour.
- [ ] Keep `FakeAdapter` as the default for tests.
- [ ] Add an OpenAI-compatible adapter later.
- [ ] Ensure LLM outputs are text/expression only.
- [ ] Add tests proving LLM adapters cannot directly mutate simulation state.

Success criteria:

- Real LLM output can make dialogue more natural.
- Removing the LLM adapter does not break deterministic simulation.

## Phase 6: Memory And Social Context

Goal: make memories useful without overbuilding retrieval too early.

TODO:

- [ ] Add recent memory queries.
- [ ] Add important memory queries.
- [ ] Add memory decay or summarization rules.
- [ ] Add relationship-aware context selection.
- [ ] Avoid vector search until simple memory retrieval is insufficient.

Success criteria:

- Proactive outputs can reference relevant past events.
- Memory behavior remains explainable and testable.

## Phase 7: Packaging And Community Readiness

Goal: make the project approachable as an early open-source runtime.

TODO:

- [ ] Add license.
- [ ] Add contribution guide.
- [ ] Add code of conduct if the project becomes public-facing.
- [ ] Add CI for formatting and tests.
- [ ] Add Hex package metadata when the API is stable enough.
- [ ] Add examples directory.
- [ ] Add issue templates for bugs, ideas, and demo scenarios.

Success criteria:

- New contributors can run tests and demos quickly.
- The project communicates what is stable and what is experimental.

## Near-Term Priority

Recommended next tasks:

1. Stabilize the public API and event/output shapes.
2. Add `mix demo.interactive`.
3. Add JSON persistence.
4. Add CI for `mix format --check-formatted` and `mix test`.
5. Add a license and contribution basics.

The project should avoid Phoenix, vector databases, distributed BEAM, and real LLM providers until the core runtime interface is clearer.
