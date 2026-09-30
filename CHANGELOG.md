# Changelog

All notable changes to Aethrion are documented here. The project is in early alpha; minor versions may contain breaking changes.

## v0.2.0-alpha

The social layer release: characters now act on each other, every change is explainable, and language models can phrase what happens without deciding it.

### Added

- **Rule pipeline.** `Aethrion.Rule` behaviour (`use Aethrion.Rule, id: ..., description: ...`) and an explicit `Aethrion.Pipeline` mapping event types to ordered rules, plus reactive rules that run after every event. Hosts can append, prepend, and remove rules, and register custom event types. `mix aethrion.rules` prints the pipeline.
- **Traced transitions.** Rules change state through `Aethrion.Transition`, which clamps values and records an output, a log line, and an `Aethrion.Trace` entry (rule, event, before, after) for every change. `Aethrion.Runtime.step/3` returns an `Aethrion.Step` with the full trace; every output carries `:rule` and `:event_id`.
- **Cascades.** Rules can enqueue follow-up events that go through validation and the same pipeline, with `:cause` links and depth/count limits.
- **Character-to-character behavior.** Observers remember what they see; struggling characters confide in trusted friends (`gossip_shared`); talkative characters retell rumors that fade with each hop; caring friends offer comfort (`comfort_offered`).
- **New events.** `message_sent` with a structured tone (`:warm`, `:neutral`, `:cold`, `:hostile`), `gossip_shared`, `comfort_offered`.
- **New outputs.** `:reply`, `:mood_changed`, `:character_interaction`. Expressive outputs carry `memory_refs` and a read-only `context` snapshot.
- **Richer state.** Simulated clock, cooldowns, derived moods (`:happy`, `:lonely`, `:jealous`, `:upset`), `joy`, `stress`, trait modifiers (`:sensitive`, `:calm`, `:playful`, `:talkative`).
- **Memory.** Kinds (`:experienced`, `:observed`, `:heard`), topics, sources, structured `data`, age-based strength decay, and deterministic queries in `Aethrion.Memories`.
- **Expression layer.** `Aethrion.Expression` renders outputs through an `Aethrion.LLM.Adapter`, falling back to deterministic templates on any failure. `Aethrion.Intent` lets a model propose an event from free text, limited to a closed set.
- **LLM adapters.** `Aethrion.LLM.Anthropic` (Messages API) and `Aethrion.LLM.OpenAICompatible` (OpenAI, vLLM, Ollama, llama.cpp), both on Erlang's `:httpc` with no new runtime dependencies.
- **OTP runtime.** `Aethrion.World` supervises a runtime server, scheduler, and rendering tasks. `Aethrion.RuntimeServer` gains subscriptions, event history, snapshot persistence with restore on restart, and asynchronous rendering with timeouts and crash isolation.
- **Scenarios.** JSON scenario files with a world, events, and expectations (`Aethrion.Scenario`, `mix aethrion.scenario`). Five bundled scenarios run in the test suite.
- **Reports.** `mix aethrion.report` renders a scenario as a self-contained HTML report with charts, a relationship graph, and the timeline.
- **Interactive CLI.** `say` (free text through intent interpretation), `message`, `comfort`, `why`, `context`, `timeline`, `rules`, `undo`, `save`, `load`, and `--llm anthropic|openai`.
- Property-based tests for bounds, determinism, persistence round trips, cascade causality, and the expression boundary.

### Changed

- `Aethrion.Runtime.dispatch/2` is now `dispatch/3` with options; the two-argument form still works.
- The v0.1 rule modules (`GiftRules`, `JealousyRules`, `LonelinessRules`, `ReconciliationRules`) are replaced by one module per rule under `Aethrion.Rules`.
- Proactive messages use cooldowns in simulated hours instead of firing once forever. `:jealous` now requires jealousy >= 15; a separate `:lonely` reason covers loneliness alone.
- Gift and apology memory ids now include the event id.
- The demo world gains relationships between Haru, Yuna, and Mina.
- Persistence writes format version 2 and still reads v0.1 data. Enumerated values from JSON are whitelisted instead of converted with `String.to_atom/1`.

## v0.1.0-alpha

Initial public alpha: deterministic gift, jealousy, loneliness, and reconciliation rules; scripted, interactive, and branched demos; JSON persistence; supervised runtime server and scheduler; fake LLM adapter.
