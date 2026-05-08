# Aethrion Launch Note

This is a draft for lightweight public sharing. The intended tone is early alpha feedback, not production-ready framework launch.

## Short Version

I'm building **Aethrion**, an early alpha Elixir runtime for persistent AI characters.

The core design principle: **LLMs can describe what happens, but deterministic rules decide what actually changes.**

Aethrion models memory, emotion, relationships, reconciliation, and proactive behavior as an event-driven social simulation layer. The runtime owns state and rule outcomes; LLMs are treated as expression adapters rather than the authority over what happened.

Repo: https://github.com/simulacre7/aethrion

Demo: https://github.com/simulacre7/aethrion/blob/main/assets/demo/interactive-demo.mp4

## X / Short Social Post

I'm building Aethrion, an early alpha Elixir runtime for persistent AI characters.

The idea: LLMs can describe what happens, but deterministic rules decide what actually changes.

It models memory, emotion, relationships, and proactive behavior as an event-driven social simulation layer.

The latest branch demo compares what happens when the user ignores a jealous character versus apologizes to her.

Repo: https://github.com/simulacre7/aethrion

Demo: https://github.com/simulacre7/aethrion/blob/main/assets/demo/interactive-demo.mp4

## LinkedIn / Longer Post

I started building Aethrion, an early alpha Elixir runtime for persistent AI characters.

Most AI character systems are centered on a simple loop: user message in, character response out. Aethrion explores a different model: characters with memory, emotion, relationships, and proactive behavior that evolve through deterministic state transitions.

The main design principle is simple:

> LLMs can describe what happens, but deterministic rules decide what actually changes.

That means the runtime owns relationship changes, memory creation, emotional state, and structured outputs. A character does not gain trust, store a memory, send a proactive message, or die because an LLM improvised it. Those changes come from explicit rules over inspectable state.

The current alpha includes:

- scripted and interactive CLI demos
- branched scenario demo
- public runtime API
- structured errors
- JSON persistence
- supervised GenServer runtime and scheduler
- fake LLM adapter
- tests and CI
- English/Korean README

It is not production-ready yet, but it is ready for feedback from people interested in Elixir, AI agents, social simulation, and narrative systems.

Repo: https://github.com/simulacre7/aethrion

Demo: https://github.com/simulacre7/aethrion/blob/main/assets/demo/interactive-demo.mp4

## Elixir Forum / Technical Post

I built an early alpha of Aethrion, an Elixir runtime for persistent social agents.

The project is an experiment in modeling AI characters as deterministic social simulation entities rather than prompt-only chatbots. A character can accumulate memory, relationships, emotional state, reconciliation state, and proactive outputs through events such as gifts, observations, apologies, and time ticks.

The current core loop is:

```txt
event -> deterministic rules -> updated state -> structured outputs
```

LLMs are deliberately kept outside the authoritative state path. The fake LLM adapter in the current alpha exists to prove that the runtime works without a real model.

Current features:

- `Aethrion.Runtime.dispatch/2`
- structured runtime errors
- scripted, interactive, and branched Mix demos
- supervised GenServer runtime and scheduler
- JSON persistence
- ExUnit tests
- GitHub Actions CI

I'm sharing it as early alpha and would welcome feedback on the runtime shape, public API, and where Elixir/BEAM processes should enter the design.

Repo: https://github.com/simulacre7/aethrion
