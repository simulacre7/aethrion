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

## A Shared Social Layer

The "shared" in *shared social layer* is concrete. Characters do not only react to the user; they react to each other, and what one character knows can reach another.

- **Observation.** Characters who witness an event remember it firsthand, linked by a `topic` to everyone else's memory of the same event.
- **Confiding.** A character who is struggling confides in the friend they trust most. The friend gains a secondhand memory, with its source.
- **Rumor.** Talkative characters retell what they heard. Each retelling carries less weight, so news travels a few hops along lines of trust and then stops.
- **Empathy.** A friend who cares about someone struggling offers comfort, which changes how both feel.

None of this is scripted by the host. Rules enqueue follow-up events (`gossip_shared`, `comfort_offered`), and those events pass through the same validation and rules as anything the host sends. Two host events in the demo cascade into four:

```txt
e1 user gives Mina a flower (seen by Yuna)
e2 time passes +2h
   Yuna -> user: "You looked happy with Mina earlier. I wondered if you forgot about me."
   e3 Yuna confides in Haru                     (caused by e2)
      Haru -> user: "Yuna told me you gave Mina a flower. Smooth."
      e4 Haru comforts Yuna                      (caused by e3)
```

## Explainable By Construction

Rules change state only through `Aethrion.Transition`, which records a trace entry for every change: which rule, in response to which event, from what value to what value. Asking "why is Yuna jealous?" has a precise answer:

```txt
e1 observation: yuna.jealousy 0 -> 15
e1 observation: yuna->mina.tension 0 -> 8
e1 mood: yuna.mood neutral -> jealous
```

Because rules are pure, the same events always produce the same world. That makes social behavior testable: the bundled scenarios are JSON files with expectations, and they run in the test suite.

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

The alpha also includes an OTP layer:

- `Aethrion.RuntimeServer` keeps runtime state inside a GenServer, with subscriptions, history, and snapshot persistence
- `Aethrion.Scheduler` emits scheduled `time_tick` events
- expression rendering runs in supervised tasks with timeouts, so a slow or crashing model never blocks or breaks the world
- `Aethrion.World` supervises all of it as one unit
- all of it delegates state transitions back to the deterministic core

This keeps the BEAM value concrete without making every character a process too early. Characters remain plain data; processes model runtime concerns.

## Related Influence

Aethrion is not built on Jido and does not depend on it today.

[Jido](https://jido.run/ecosystem/jido) is adjacent inspiration for thinking about long-running autonomous agents on the BEAM, especially the separation between deterministic agent logic, explicit effects, and supervised runtime execution.

Aethrion applies similar BEAM-friendly ideas to a narrower domain: persistent social simulation for AI characters. The current focus is not general-purpose agent orchestration. It is the social substrate underneath characters: memory, emotion, relationship state, events, and proactive outputs.
