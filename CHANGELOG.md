# Changelog

All notable changes to Aethrion are documented here. The project is in early alpha; minor versions may contain breaking changes.

## v0.2.0-alpha

The social layer release: characters now act on each other, every change is explainable, and language models can phrase what happens without deciding it.

### Added

- **Rule pipeline.** `Aethrion.Rule` behaviour (`use Aethrion.Rule, id: ..., description: ...`) and an explicit `Aethrion.Pipeline` mapping event types to ordered rules, plus reactive rules that run after every event. Hosts can append, prepend, and remove rules, and register custom event types. `mix aethrion.rules` prints the pipeline.
- **Explain.** `Aethrion.Explain` answers why a single value is what it is: every change, the rule that made it, and the chain of events that caused it (`why yuna jealousy` in the interactive demo).
- **Traced transitions.** Rules change state through `Aethrion.Transition`, which clamps values and records an `Aethrion.Trace` entry (rule, event, before, after) for every change, plus outputs and log lines where they apply. `Aethrion.Runtime.step/3` returns an `Aethrion.Step` with the full trace; every output carries `:rule` and `:event_id`.
- **Cascades.** Rules can enqueue follow-up events that go through validation and the same pipeline, with `:cause` links and depth/count limits (the event limit scales with the number of characters; runtime servers and worlds accept `max_depth`/`max_events`).
- **Character-to-character behavior.** Observers remember what they see; struggling characters confide in trusted friends (`gossip_shared`); talkative characters retell rumors that fade with each hop; caring friends offer comfort (`comfort_offered`); lonely characters spend time with their closest friend (`time_spent_together`).
- **New events.** `message_sent` with a structured tone (`:warm`, `:neutral`, `:cold`, `:hostile`), `gossip_shared`, `comfort_offered`, `time_spent_together`.
- **New outputs.** `:reply`, `:mood_changed`, `:character_interaction`. Expressive outputs carry `memory_refs` and a read-only `context` snapshot.
- **Richer state.** Simulated clock, cooldowns, derived moods (`:happy`, `:lonely`, `:jealous`, `:upset`), `joy`, `stress`, trait modifiers (`:sensitive`, `:calm`, `:playful`, `:talkative`).
- **Memory.** Kinds (`:experienced`, `:observed`, `:heard`, `:impression`), topics, sources, structured `data`, age-based strength decay, and deterministic queries in `Aethrion.Memories`.
- **History matters.** Impressions change how messages land: a record of kindness halves the impact of cold or hostile words (and the reply says "That's not like you"), repeated hostility halves the impact of warmth.
- **Forgetting.** Memories faded for 30 simulated days (tunable) are removed, with a trace entry, so long-running worlds stay bounded.
- **Consolidation.** Faded memories of the same interaction with the same actor fold into a lasting impression ("user has been warm to mina 3 times."), deterministically.
- **Expression layer.** `Aethrion.Expression` renders outputs through an `Aethrion.LLM.Adapter`, falling back to deterministic templates on any failure. `Aethrion.Intent` lets a model propose an event from free text, limited to a closed set.
- **Korean templates.** `FakeAdapter` renders every line in Korean with `locale: :ko` (particles chosen from names), and `mix demo.interactive --locale ko` shows both languages. The simulation is identical in every language.
- **LLM adapters.** `Aethrion.LLM.Anthropic` (Messages API) and `Aethrion.LLM.OpenAICompatible` (OpenAI, vLLM, Ollama, llama.cpp), both on Erlang's `:httpc` with no new runtime dependencies.
- **OTP runtime.** `Aethrion.World` supervises a runtime server, scheduler, and rendering tasks. `Aethrion.RuntimeServer` gains subscriptions, event history, snapshot persistence with restore on restart, and asynchronous rendering with timeouts and crash isolation.
- **Tuning.** Every rule declares its numbers (including message tone effects) as `params`; a world can override them in `state.tuning` (`Aethrion.Tuning`), in saved state, or in a scenario's `"tuning"` block. `mix aethrion.rules` prints them.
- **Custom events in JSON.** Scenarios and journals accept event types registered in a custom pipeline when loaded with `pipeline:`, without creating atoms from input.
- **Journals.** `Aethrion.Journal` stores a world as its starting state plus an append-only log of host events; replay rebuilds it exactly and detects mismatches. Worlds can journal every dispatch and rebuild on restart (`journal:`), and `mix aethrion.journal` replays and exports a journal as a scenario or report.
- **Scenarios.** JSON scenario files with a world, events, and expectations (`Aethrion.Scenario`, `mix aethrion.scenario`). Ten bundled scenarios run in the test suite.
- **Branches.** Scenarios can define alternative futures after shared events; each branch has its own expectations, and reports compare branches side by side. The bundled `07_crossroads.json` plays one moment four ways.
- **Reports.** `mix aethrion.report` renders a scenario as a self-contained HTML report with charts, a relationship graph, and the timeline.
- **Interactive CLI.** `say` (free text through intent interpretation), `message`, `comfort`, `why`, `context`, `timeline`, `rules`, `undo`, `save`, `load`, `record` (the session as a replayable scenario with snapshot expectations), `report` (the session as an HTML report), and `--llm anthropic|openai`.
- Property-based tests for bounds, determinism, persistence round trips, cascade causality, and the expression boundary.

### Changed

- Characters do not proactively reach out to someone they feel tense toward (tension >= 10, `proactive.avoid_tension`); they confide in friends instead.
- Untrusted data is validated: `Aethrion.State.parse/1` checks shapes, types, and ranges; unknown traits stay strings instead of becoming atoms; a runtime server refuses to start from an unreadable snapshot rather than overwrite it.
- Hand-built event maps may omit `:at`, `:now`, `:observed_by`, and `:tone`. Inactive or blocked characters cannot comfort or gossip (`:unavailable_character`), and characters cannot give themselves gifts.
- A rule that raises inside a `RuntimeServer` rejects the event with `:rule_failed` instead of crashing the world.

- `Aethrion.Runtime.dispatch/2` is now `dispatch/3` with options; the two-argument form still works.
- The v0.1 rule modules (`GiftRules`, `JealousyRules`, `LonelinessRules`, `ReconciliationRules`) are replaced by one module per rule under `Aethrion.Rules`.
- Proactive messages use cooldowns in simulated hours instead of firing once forever. `:jealous` now requires jealousy >= 15; a separate `:lonely` reason covers loneliness alone.
- Gift and apology memory ids now include the event id.
- The demo world gains relationships between Haru, Yuna, and Mina.
- Persistence writes format version 2 and still reads v0.1 data. Enumerated values from JSON are whitelisted instead of converted with `String.to_atom/1`.

## v0.1.0-alpha

Initial public alpha: deterministic gift, jealousy, loneliness, and reconciliation rules; scripted, interactive, and branched demos; JSON persistence; supervised runtime server and scheduler; fake LLM adapter.
