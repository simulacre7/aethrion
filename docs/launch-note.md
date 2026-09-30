# Aethrion Launch Note

Drafts for lightweight public sharing of v0.2.0-alpha. The intended tone is early alpha feedback, not a production-ready framework launch.

## Short Version

Aethrion v0.2 is out: an early alpha Elixir runtime where AI characters remember, relate, and act on each other, not just on the user.

The core design principle: **LLMs can describe what happens, but deterministic rules decide what actually changes.**

In the demo, the host sends two events (a gift one character witnesses, and two hours passing). The rules turn that into a proactive message, a confidence between two characters, a tease, and an act of comfort. Every one of those changes is traced to the rule and event that caused it.

Repo: https://github.com/simulacre7/aethrion

## X / Short Social Post

Aethrion v0.2: an Elixir runtime for AI characters that affect each other.

Two events in: a gift Yuna sees, two hours pass.
Out: Yuna messages you and confides in Haru; Haru teases you, then comforts Yuna.

No LLM decided any of it. Rules did, and `why yuna` shows exactly which.

https://github.com/simulacre7/aethrion

## LinkedIn / Longer Post

I've released v0.2 of Aethrion, an early alpha Elixir runtime for persistent AI characters.

Most AI character systems are a loop between one user and one character. Aethrion treats characters as a small society: they notice what happens around them, confide in the people they trust, pass news along, comfort each other, and slowly turn many small moments into lasting impressions.

The design principle hasn't changed:

> LLMs can describe what happens, but deterministic rules decide what actually changes.

What's new in v0.2:

- characters act on each other through cascading events: confiding, rumors that fade with each retelling, empathy, comfort
- every state change is traced to a rule and an event, so "why does Yuna feel this way?" has a precise answer
- a real LLM boundary: Anthropic and OpenAI-compatible adapters can phrase lines from read-only snapshots and propose what free text means, but cannot change state; failures fall back to deterministic text
- relationship history matters: a long record of kindness softens one harsh message
- rule parameters are data, so two worlds can run the same rules with a different temperament
- JSON scenarios with expectations and what-if branches, rendered as HTML reports
- a supervised OTP "world" that keeps running while slow or failing model calls are isolated

It's alpha and the API will move, but it's ready for feedback from people working on narrative systems, games, companions, and agents on the BEAM.

Repo: https://github.com/simulacre7/aethrion

## Elixir Forum / Technical Post

Aethrion v0.2.0-alpha is a deterministic social simulation runtime for AI characters, written in Elixir.

The core loop:

```txt
event -> validate -> rule pipeline -> follow-up events (cascade)
      -> state + structured outputs + trace
      -> optional LLM rendering, outside the authoritative path
```

Some design choices that may be interesting here:

- **Rules are plain modules** (`use Aethrion.Rule`) organized by an explicit pipeline. They change state only through a `Transition` accumulator, which clamps values and records a trace entry for every change. The same events always produce the same world, so there are property tests for bounds, determinism, persistence round trips, and cascade causality.
- **Cascades instead of actors.** Characters are plain data, not processes. Social behavior between characters happens through follow-up events that rules enqueue and the runtime processes breadth-first with depth and count limits.
- **OTP where it earns its place.** `Aethrion.World` supervises a runtime server (state, subscriptions, history, snapshot restore), a scheduler, and a `Task.Supervisor` for LLM rendering. Dispatch never waits on a model; slow renders time out, crashed ones are isolated, and subscribers get deterministic fallback text either way.
- **A narrow LLM boundary.** Adapters receive read-only snapshots, return text, and can propose intents only from a closed set; the proposed event still goes through validation and rules. Adapters use `:httpc`, so the only runtime dependency is `jason`.
- **Data-first scenarios.** JSON files with a world, events, expectations, branches, and per-world rule tuning. They run in CI and render as self-contained HTML reports.

I'd welcome feedback on the rule and pipeline API, the cascade model versus per-character processes, and the expression boundary.

Repo: https://github.com/simulacre7/aethrion
