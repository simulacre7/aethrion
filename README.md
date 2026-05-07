# Aethrion

**Pronunciation:** 에이트리온 / ay-three-on

**A shared social layer for persistent AI characters.**

Aethrion is a persistent social simulation runtime for AI characters that remember, relate, and act over time.

Inspired by the ancient idea of aether, Aethrion treats memory, relationships, and autonomous interaction as a shared social layer where persistent agents can live, change, and respond to each other.

## Why This Exists

Most AI character systems are built around a simple loop:

```txt
user -> character -> response
```

Aethrion explores a different model:

```txt
character <-> character
character <-> world
character <-> user
```

The goal is not to make an LLM improvise every fact. The goal is to make relationships, memories, emotions, and proactive behavior emerge from deterministic state transitions.

## How It Differs From A Chatbot

A normal chatbot usually asks the model what should happen next. Aethrion keeps authoritative state in the runtime.

```txt
Deterministic simulation core
+ LLM reasoning/expression layer
```

The runtime owns:

- character state
- relationship changes
- memory creation
- rule evaluation
- scheduled or proactive behavior
- structured outputs

The LLM layer only helps express the result in natural language. The v0 demo uses a fake LLM adapter to prove the simulation works without a real model.

## Demo Preview

```txt
[Event] user gives Mina a flower
[Rule] Mina affinity toward user +10
[Memory] Mina remembers the flower
[Rule] Yuna notices the gift
[State] Yuna jealousy +15

[Event] time passes
[Rule] Yuna loneliness +8
[Output] Yuna proactively messages the user
```

Run it with:

```bash
mix demo.drama
```

## Local Setup

This project is an Elixir Mix library. No Phoenix, database, vector store, or real LLM provider is required for v0.

```bash
mix deps.get
mix test
mix demo.drama
```

Recommended local versions:

- Elixir 1.19.x
- Erlang/OTP 28.x

## Current MVP Scope

- 3 demo characters: Mina, Yuna, Haru
- relationship graph
- memory store
- deterministic rules
- proactive messaging
- fake LLM adapter
- CLI drama demo

See [docs/concept.md](docs/concept.md) and [docs/mvp.md](docs/mvp.md) for more detail.
