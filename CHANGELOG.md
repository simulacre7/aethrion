# Changelog

All notable changes to Aethrion are documented here. The project is in early alpha; minor versions may contain breaking changes.

## v0.2.0-alpha

The social layer release: characters act on each other, every change is explainable, relationship history changes outcomes, and language models can phrase what happens without deciding it.

### Added

**Rules and explainability**

- `Aethrion.Rule` behaviour (`use Aethrion.Rule, id:, description:, params:`) and an explicit `Aethrion.Pipeline` of event rules plus reactive rules that run after every event. Hosts can append, prepend, and remove rules and register custom event types. `mix aethrion.rules` prints the pipeline and every parameter.
- `Aethrion.Transition` and `Aethrion.Trace`: rules change state only through tracked helpers, so every change records the rule, the event, and the before/after values. `Aethrion.Runtime.step/3` returns an `Aethrion.Step` with the full trace, and every output carries `:rule` and `:event_id`.
- `Aethrion.Digest`: what changed socially over a stretch of outputs, as short English or Korean lines for people ("while you were away").
- `Aethrion.Explain`: every change to one value, with the rule and the chain of events behind it (`why yuna jealousy` in the interactive demo).
- `Aethrion.Tuning`: every rule number is a declared parameter that a world, saved state, or scenario can override without code.
- Cascades: rules enqueue follow-up events that pass through validation and the same pipeline, linked by `:cause`, with depth and count limits (the count limit scales with the number of characters).

**Social behavior**

- Observers remember what they see; struggling characters confide in the friend they trust most (`gossip_shared`); talkative characters retell rumors that lose weight with every hop; caring friends offer comfort (`comfort_offered`); lonely characters spend time with their closest friend (`time_spent_together`).
- `message_sent` with a structured tone (`:warm`, `:neutral`, `:cold`, `:hostile`) and replies; characters remember when each person last talked to them and notice a long absence. Hurt feelings color replies before the mood does; replies vary instead of repeating and escalate when insults do; gifts and apologies get replies too (apologies grateful at first, wearier with each repeat).
- Bonds (`:estranged`, `:strained`, `:neutral`, `:friendly`, `:close`) name what a relationship has become; a `:bond_changed` output announces when an event moves one, and bonds color replies when the mood does not. A bond holds until the numbers move 5 points past its threshold, so it settles instead of flickering.
- A simulated clock, cooldowns, derived moods (`:happy`, `:lonely`, `:jealous`, `:upset`), `joy`, `stress`, and trait modifiers (`:sensitive`, `:calm`, `:playful`, `:talkative`).
- The rules hold together over weeks of mixed play: a kind word after days away eases half the loneliness that built up, and kind words ease leftover tension; replies come from the mood the words found; a week of cold words is noticed and escalates; bonds do not warm while tension is high; lonely messages quote each kind word once and wait a day after a brush-off; hearing about an apology is good news; a player's own digest calls them "you".
- Several players in one world: `State` `people` display names ("Alex", not `"player:alex"`), a digest per player (`only_you: true`), jealousy felt once a day per giver and aimed at the giver who caused it, a cap on goodwill earned only by being seen, varied words when several witnesses speak up, no gossip about harsh words that were apologized for, and grouped outings in digests.
- Proactive messages address people: jealousy goes to the gift's giver, loneliness to the closest person they like enough, curiosity to the person the news is about. Characters do not reach out to someone they feel tense toward, a character who saw a person be hostile to a friend speaks up to them (`:protective`), and a lonely message that gets no reply is followed by silence for three days (a week after a week of silence), not a daily repeat; being ignored costs a little affinity.
- Loneliness grows only after 16 hours without company, so a character talked to every day stays content; jealousy and tension fade a little each day, and ease faster with apologies and comfort. Apologies wear thin: each one still remembered halves the trust and tension the next one repairs.
- Reputation: messages and apologies take `observed_by`; witnesses and those who hear the story judge the sender by how they treated someone the judge cares about. Faded secondhand memories of messages fold into reputation impressions ("haru knows user has been hostile to mina and yuna 2 times."), which change how the sender's own messages land when there is no firsthand history, and how characters reply. Each event counts once, even when its details are forgotten and the story is heard again.

**Memory**

- Memory kinds (`:experienced`, `:observed`, `:heard`, `:impression`), topics that link everyone's memory of one event, sources, and structured data.
- Age-based decay that does not depend on tick size, deterministic queries in `Aethrion.Memories`, and forgetting of long-faded memories so worlds stay bounded.
- Consolidation: faded memories of the same interaction with the same actor fold into a lasting impression ("user has been warm to mina 3 times."). Impressions change how later messages land: a record of kindness halves the impact of harsh words, repeated hostility halves the impact of warmth.

**Language models**

- Expressive outputs (`:proactive_message`, `:reply`, `:character_interaction`) carry deterministic fallback text, `memory_refs`, and a read-only `context` snapshot.
- `Aethrion.Expression` renders outputs through an `Aethrion.LLM.Adapter` and keeps the fallback text on any failure, an overlong line, or a silence; model lines are kept to one line. Prompts say how long it has been since the listener last talked to the speaker, how old each memory is, and what the rules weighed for a reply. `Aethrion.Intent` lets a model propose an event from free text, limited to a closed set.
- Adapters: `Aethrion.LLM.Anthropic` (Messages API), `Aethrion.LLM.OpenAICompatible` (OpenAI, vLLM, Ollama, llama.cpp), both on Erlang's `:httpc`; `FakeAdapter` gains Korean templates (`locale: :ko`) and reads Korean free text; model adapters take `language:` to write in another language.

**Runtime and persistence**

- `Aethrion.World` supervises a runtime server, a scheduler, and rendering tasks. Subscribers stay subscribed when the runtime restarts and receive `{:aethrion, world_name, payload}`, so one process can listen to many worlds; `dispatch/2` and `step/2` on a world that is not running return `:world_not_running`; `whereis/1` finds a world to stop; `put_state/2` loads a save into a journaled world by starting its journal over.
- `Aethrion.RuntimeServer` gains subscriptions, event history, cascade limits, snapshot persistence with restore, and asynchronous rendering with timeouts and crash isolation. A rule that raises rejects the event (`:rule_failed`) instead of crashing the world.
- `Aethrion.Journal`: a world as its starting state plus an append-only log of host events. Replay rebuilds it exactly and detects mismatches; servers can journal every dispatch and rebuild from it on start. Compaction (`Journal.compact/2`, `World.compact_journal/1`, the `:journal_compact_every` option, `mix aethrion.journal --compact`) restarts a journal from the current state, optionally archiving the old one. Journal headers record the Aethrion version, and reading one written by another version logs a warning. A last line cut short by a crash is dropped (and repaired by a server on start); snapshots are written atomically.

**Scenarios and tooling**

- JSON scenarios with a world, events, expectations, branches, tuning, and custom events (`Aethrion.Scenario`, `mix aethrion.scenario`), with a JSON Schema. Fourteen bundled scenarios run in the test suite, one with a Korean cast.
- Self-contained HTML reports (`mix aethrion.report`, `--locale ko` for a Korean report, memories included) with charts, what each character has come to believe, a relationship graph with bond changes, the timeline, and branch comparison.
- Scenario output and memory expectations are validated when loaded, so a misspelled type, key, or value is an error instead of a silently passing `"count": 0`. Extreme tuning stays sane: no bond is made permanent by a wide hysteresis, `settled_tension` 0 turns its check off, and characters never write more than once an hour.
- Mix tasks reject options and arguments they do not understand, say why a file could not be written or read (and point a scenario file handed to the journal tools to `mix aethrion.scenario`), write UTF-8 whatever the shell locale, and `mix aethrion.scenario --all --json` prints one JSON array. The interactive demo suggests the command you probably meant.
- `mix aethrion.scenario --pipeline Module.function` runs scenarios of custom rules. `Intent.interpret/3` takes `:observed_by`. A runtime server refuses to start from a journal whose tuning its pipeline cannot hold, instead of dropping it.
- `mix aethrion.journal` replays a journal, prints its digest, and exports it as a scenario or report.
- Interactive CLI: `say`, `message`, `comfort`, `here` (witnesses), `opinion`, `digest`, `why`, `context`, `timeline`, `rules`, `undo`, `save`, `load`, `record`, `report`, `--llm`, and `--locale ko`.
- A tutorial (English and Korean), a cookbook for hosts, rules reference, expression guide, scenario format, and API reference; a benchmark in `bench/`.
- Property-based tests for bounds, determinism, persistence and journal round trips, session recording, cascade causality, bond announcements, and the expression boundary; soak tests that crash journaled and snapshotting worlds; README excerpts checked against real output. `mix check` runs the local suite; CI adds Dialyzer, Credo, each scenario in a fresh VM, and the examples.

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
