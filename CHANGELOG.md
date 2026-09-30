# Changelog

All notable changes to Aethrion are documented here. The project is in early alpha; minor versions may contain breaking changes.

## v0.2.0-alpha

The social layer release: characters act on each other, every change is explainable, relationship history changes outcomes, and language models can phrase what happens without deciding it.

### Added

**Rules and explainability**

- `Aethrion.Rule` behaviour (`use Aethrion.Rule, id:, description:, params:`) and an explicit `Aethrion.Pipeline` of event rules plus reactive rules that run after every event. Hosts can append, prepend, and remove rules and register custom event types. `mix aethrion.rules` prints the pipeline and every parameter.
- `Aethrion.Transition` and `Aethrion.Trace`: rules change state only through tracked helpers, so every change records the rule, the event, and the before/after values. `Aethrion.Runtime.step/3` returns an `Aethrion.Step` with the full trace, and every output carries `:rule` and `:event_id`.
- `Aethrion.Explain`: every change to one value, with the rule and the chain of events behind it (`why yuna jealousy` in the interactive demo).
- `Aethrion.Tuning`: every rule number is a declared parameter that a world, saved state, or scenario can override without code.
- Cascades: rules enqueue follow-up events that pass through validation and the same pipeline, linked by `:cause`, with depth and count limits (the count limit scales with the number of characters).

**Social behavior**

- Observers remember what they see; struggling characters confide in the friend they trust most (`gossip_shared`); talkative characters retell rumors that lose weight with every hop; caring friends offer comfort (`comfort_offered`); lonely characters spend time with their closest friend (`time_spent_together`).
- `message_sent` with a structured tone (`:warm`, `:neutral`, `:cold`, `:hostile`) and replies.
- Derived bonds (`:estranged`, `:strained`, `:neutral`, `:friendly`, `:close`) name what a relationship has become; a `:bond_changed` output announces when an event moves one, and bonds color replies when the mood does not.
- A simulated clock, cooldowns, derived moods (`:happy`, `:lonely`, `:jealous`, `:upset`), `joy`, `stress`, and trait modifiers (`:sensitive`, `:calm`, `:playful`, `:talkative`).
- Proactive messages address people: jealousy goes to the gift's giver, loneliness to the closest person, curiosity to the person the news is about. Characters do not reach out to someone they feel tense toward, and a character who saw a person be hostile to a friend speaks up to them (`:protective`).
- Tension eases through apologies, comfort, and time.
- Reputation: messages and apologies take `observed_by`; witnesses and those who hear the story judge the sender by how they treated someone the judge cares about. Faded secondhand memories of messages fold into reputation impressions ("haru knows user has been hostile to mina and yuna 2 times."), which change how the sender's own messages land when there is no firsthand history, and how characters reply. Each event counts once, even when its details are forgotten and the story is heard again.

**Memory**

- Memory kinds (`:experienced`, `:observed`, `:heard`, `:impression`), topics that link everyone's memory of one event, sources, and structured data.
- Age-based decay that does not depend on tick size, deterministic queries in `Aethrion.Memories`, and forgetting of long-faded memories so worlds stay bounded.
- Consolidation: faded memories of the same interaction with the same actor fold into a lasting impression ("user has been warm to mina 3 times."). Impressions change how later messages land: a record of kindness halves the impact of harsh words, repeated hostility halves the impact of warmth.

**Language models**

- Expressive outputs (`:proactive_message`, `:reply`, `:character_interaction`) carry deterministic fallback text, `memory_refs`, and a read-only `context` snapshot.
- `Aethrion.Expression` renders outputs through an `Aethrion.LLM.Adapter` and keeps the fallback text on any failure. `Aethrion.Intent` lets a model propose an event from free text, limited to a closed set.
- Adapters: `Aethrion.LLM.Anthropic` (Messages API), `Aethrion.LLM.OpenAICompatible` (OpenAI, vLLM, Ollama, llama.cpp), both on Erlang's `:httpc`; `FakeAdapter` gains Korean templates (`locale: :ko`).

**Runtime and persistence**

- `Aethrion.World` supervises a runtime server, a scheduler, and rendering tasks.
- `Aethrion.RuntimeServer` gains subscriptions, event history, cascade limits, snapshot persistence with restore, and asynchronous rendering with timeouts and crash isolation. A rule that raises rejects the event (`:rule_failed`) instead of crashing the world.
- `Aethrion.Journal`: a world as its starting state plus an append-only log of host events. Replay rebuilds it exactly and detects mismatches; servers can journal every dispatch and rebuild from it on start. Compaction (`Journal.compact/2`, `World.compact_journal/1`, the `:journal_compact_every` option, `mix aethrion.journal --compact`) restarts a journal from the current state, optionally archiving the old one. Journal headers record the Aethrion version, and reading one written by another version logs a warning.

**Scenarios and tooling**

- JSON scenarios with a world, events, expectations, branches, tuning, and custom events (`Aethrion.Scenario`, `mix aethrion.scenario`), with a JSON Schema. Thirteen bundled scenarios run in the test suite.
- Self-contained HTML reports (`mix aethrion.report`, `--locale ko` for Korean lines) with charts, a relationship graph, the timeline, and branch comparison.
- `mix aethrion.journal` replays a journal and exports it as a scenario or report.
- Interactive CLI: `say`, `message`, `comfort`, `here` (witnesses), `opinion`, `why`, `context`, `timeline`, `rules`, `undo`, `save`, `load`, `record`, `report`, `--llm`, and `--locale ko`.
- A tutorial (English and Korean), rules reference, expression guide, scenario format, and API reference; a benchmark in `bench/`.
- Property-based tests for bounds, determinism, persistence and journal round trips, session recording, cascade causality, and the expression boundary. CI runs Dialyzer and the examples.

### Changed

- `Aethrion.Runtime.dispatch/2` is now `dispatch/3` with options; the two-argument form still works.
- The v0.1 rule modules (`GiftRules`, `JealousyRules`, `LonelinessRules`, `ReconciliationRules`) are replaced by one module per rule under `Aethrion.Rules`.
- Proactive messages use cooldowns in simulated hours instead of firing once forever. `:jealous` now requires jealousy >= 15; a separate `:lonely` reason covers loneliness alone.
- Apologies also ease tension toward the apologizer.
- Gift and apology memory ids include the event id.
- The demo world gains relationships between Haru, Yuna, and Mina.
- Persistence writes format version 2 and still reads v0.1 data.
- Event constructors default `:at` to `"unspecified"` instead of `"demo:t0"`.
- The scheduler's `:notify` message is `{:aethrion, scheduler_pid, {:scheduler_tick, result}}`, following the library's message convention.
- Persistence adapters report "nothing saved yet" as `{:error, %Aethrion.Error{code: :not_found}}`, and every public function that can fail returns `%Aethrion.Error{}` with location details; `Aethrion.Error.format/1` renders the message with its location.
- The `mix demo.*` tasks live in `dev/` and are no longer part of the package.

### Fixed and hardened

- Untrusted data cannot create atoms: enumerated values are whitelisted and unknown traits stay strings. `Aethrion.State.parse/2` validates shapes, types, and ranges and reports the path of the first problem.
- A runtime server refuses to start from an unreadable snapshot or journal rather than overwrite it, and a journaling server writes the journal before committing state.
- Event time labels (`:at`, `:now`) must be strings; hand-built events may omit them. Inactive or blocked characters cannot comfort, gossip, or spend time together (`:unavailable_character`), and characters cannot give themselves gifts.

## v0.1.0-alpha

Initial public alpha: deterministic gift, jealousy, loneliness, and reconciliation rules; scripted, interactive, and branched demos; JSON persistence; supervised runtime server and scheduler; fake LLM adapter.
