# Aethrion Launch Note

This is a draft for lightweight public sharing. The intended tone is early alpha feedback, not production-ready framework launch.

## Short Version

I'm building **Aethrion**, an early alpha Elixir runtime for persistent AI characters.

The core idea: **LLMs express the drama, but deterministic state creates it.**

Aethrion models memory, emotion, relationships, and proactive behavior as an event-driven social simulation layer. The runtime owns state transitions; LLMs are treated as expression adapters rather than the authority over what happened.

Repo: https://github.com/simulacre7/aethrion

Demo: https://github.com/simulacre7/aethrion/blob/main/assets/demo/interactive-demo.mp4

## X / Short Social Post

I'm building Aethrion, an early alpha Elixir runtime for persistent AI characters.

The idea: LLMs express the drama, but deterministic state creates it.

It models memory, emotion, relationships, and proactive behavior as an event-driven social simulation layer.

Repo: https://github.com/simulacre7/aethrion

Demo: https://github.com/simulacre7/aethrion/blob/main/assets/demo/interactive-demo.mp4

## LinkedIn / Longer Post

I started building Aethrion, an early alpha Elixir runtime for persistent AI characters.

Most AI character systems are centered on a simple loop: user message in, character response out. Aethrion explores a different model: characters with memory, emotion, relationships, and proactive behavior that evolve through deterministic state transitions.

The main design principle is simple:

> LLMs express the drama, but deterministic state creates it.

That means the runtime owns relationship changes, memory creation, emotional state, and structured outputs. LLMs can make the final expression more natural, but they do not directly mutate authoritative state.

The current alpha includes:

- scripted and interactive CLI demos
- public runtime API
- structured errors
- JSON persistence
- fake LLM adapter
- tests and CI
- English/Korean README

It is not production-ready yet, but it is ready for feedback from people interested in Elixir, AI agents, social simulation, and narrative systems.

Repo: https://github.com/simulacre7/aethrion

Demo: https://github.com/simulacre7/aethrion/blob/main/assets/demo/interactive-demo.mp4

## Elixir Forum / Technical Post

I built an early alpha of Aethrion, an Elixir runtime for persistent social agents.

The project is an experiment in modeling AI characters as deterministic social simulation entities rather than prompt-only chatbots. A character can accumulate memory, relationships, emotional state, and proactive outputs through events such as gifts, observations, and time ticks.

The current core loop is:

```txt
event -> deterministic rules -> updated state -> structured outputs
```

LLMs are deliberately kept outside the authoritative state path. The fake LLM adapter in the current alpha exists to prove that the runtime works without a real model.

Current features:

- `Aethrion.Runtime.dispatch/2`
- structured runtime errors
- scripted and interactive Mix demos
- JSON persistence
- ExUnit tests
- GitHub Actions CI

I'm sharing it as early alpha and would welcome feedback on the runtime shape, public API, and where Elixir/BEAM processes should enter the design.

Repo: https://github.com/simulacre7/aethrion
