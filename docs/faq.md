# FAQ

## Why not let the LLM decide what happens?

Because then nothing is inspectable, testable, or stable. If a model decides that Yuna now trusts the user more, you cannot say why, cannot reproduce it, and cannot write a test that it stays true tomorrow. In Aethrion a model can phrase what happened and can propose what a user's free text means, but every state change comes from a rule you can read, trace (`why yuna->user trust`), tune, and test. Removing the model leaves the simulation intact; only the wording gets plainer.

## Then what is the LLM for?

Voice. Rules produce the facts and a deterministic draft line; a model rewrites the line in the character's voice from a read-only snapshot of their profile, mood, relationship, and relevant memories. It can also classify free text into a closed set of intents (a message with a tone, or an apology). See [expression.md](expression.md).

## Why not one process per character?

Characters are data that rules read and write together: a single gift changes the receiver, every observer, and their relationships at once, and a cascade can touch several characters in one step. Splitting that across processes would turn one deterministic function into a distributed protocol with ordering problems, for no benefit at this scale. Processes are used where they help: the long-running world, the scheduler, and isolating slow or failing model calls. See the Phase 4 notes in the [roadmap](roadmap.md).

## Is it really deterministic?

For the same starting state, events, pipeline, and cascade limits: yes, and the test suite checks it with property tests over random event sequences, journal replay, and session recording. Rules never read the wall clock or use randomness, iterate characters in sorted order, and compute time-based effects from the simulated clock. Results can change between Aethrion versions when rules change; a journal or scenario records inputs, so replaying it on a new version shows exactly what moved.

## How big can a world be?

`bench/dispatch.exs` builds a world of N characters in a ring of trust and runs gifts, messages, and ticks. On a laptop, 200 characters over 96 simulated hours (about 2,700 processed events and 5,000 memories) run in about 4 seconds, around 1.5 ms per event; a tick that triggers dozens of cascaded outings takes tens of milliseconds. Memories are forgotten after 30 faded days by default, so long-running worlds stay bounded. Cascades per event scale with the number of characters (`max_events`).

## Can I use it with Phoenix, a game engine, or a chat app?

Yes, as a library. Keep the state wherever you like (a `Aethrion.World` process, your own GenServer, a database via a `Aethrion.Persistence` adapter or a journal), dispatch events when things happen, and handle the outputs: show messages, render scenes, trigger animations from mood changes. Aethrion itself has no UI and no web dependency.

## Can there be more than one human?

Yes. Any actor id that is not a character is a person. Characters address proactive messages to people they have relationships with: jealousy to the giver of the gift they saw, loneliness to the person they feel closest to, curiosity to the person the news is about. A world with no relationships to people addresses `"user"`. See the `11_two_regulars.json` scenario.

## How do I change how characters behave?

In order of effort:

1. **Tune** numbers without code: `Aethrion.Tuning.put/4` or a scenario's `"tuning"` block (`mix aethrion.rules` lists every parameter).
2. **Remove** a rule from the pipeline (`Pipeline.remove/2`), for example to switch off gossip.
3. **Add** a rule (`use Aethrion.Rule`) for an existing or new event type.

Write a scenario with expectations for the behavior you want, and it becomes a test.

## Does it work in other languages?

Rules are language-neutral. Fallback lines exist in English and Korean (`locale: :ko`); a model adapter can write in any language. Memory contents use ids (`"user gave mina a flower."`) so they stay stable; adapters get structured `data` alongside.

## Is it production-ready?

No. It is an alpha: the API may still change, it is not published to Hex yet, and the model adapters have only been tested against a local stub server. It is ready for experiments, prototypes, and feedback.
