# Aethrion Concept

**Aethrion** (에이트리온 / ay-three-on) is a shared social layer for persistent AI characters.

It is inspired by the ancient idea of aether: an invisible medium once believed to connect and fill the heavens. In Aethrion, that medium becomes a runtime layer made of memory, relationships, events, and autonomous interaction.

## Core Idea

Aethrion is not a chatbot framework. It is a deterministic social simulation runtime where LLMs are optional expression and reasoning adapters.

The runtime remains structurally valid if the LLM is removed.

The deterministic core owns:

- state management
- relationship changes
- memory creation
- event processing
- rule evaluation
- scheduling and proactive outputs

LLMs may help with:

- dialogue generation
- emotional expression
- summarization
- intent interpretation
- narrative flavor

They should not directly mutate authoritative state.

## Persistent Social Agents

Aethrion treats characters as persistent social agents. A character can remember an event, change mood, react to another character's relationship, and later initiate an interaction without a direct user prompt.

The target feeling is closer to:

```txt
The Sims + visual novel + AI dialogue
```

than a standard request-response chat app.

## Why Elixir And BEAM

The long-term runtime model maps naturally to Elixir and BEAM:

- character agents can become lightweight processes
- schedulers can emit time-based events
- relationship coordinators can process social graph changes
- supervision can recover long-lived runtime components
- message passing fits event-driven simulation

The v0 implementation starts as a small Elixir library with a deterministic, process-free simulation core. It intentionally avoids Phoenix, distributed Erlang, persistent databases, and real LLM providers until the simulation loop is proven.

## Related Influence

Aethrion is not built on Jido and does not depend on it today.

[Jido](https://jido.run/ecosystem/jido) is adjacent inspiration for thinking about long-running autonomous agents on the BEAM, especially the separation between deterministic agent logic, explicit effects, and supervised runtime execution.

Aethrion applies similar BEAM-friendly ideas to a narrower domain: persistent social simulation for AI characters. The current focus is not general-purpose agent orchestration. It is the social substrate underneath characters: memory, emotion, relationship state, events, and proactive outputs.
