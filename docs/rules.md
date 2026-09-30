# Rules

Every state change in Aethrion comes from a rule. This page lists the built-in rules, the numbers they use, and how they are organized. The same list, generated from code, is available with:

```bash
mix aethrion.rules
```

## How a dispatch runs

```txt
host event
  -> validate
  -> event rules for its type, in order
  -> reactive rules (mood, proactive), for every event
  -> follow-up events enqueued by rules, breadth-first,
     each validated and run through the same pipeline
```

- Rules are modules implementing `Aethrion.Rule` (`id/0`, `description/0`, `apply/1`).
- Which rules run for which event is decided by `Aethrion.Pipeline`, not by the rules.
- Rules change state only through `Aethrion.Transition` helpers, which clamp values and record an `Aethrion.Trace` entry tagged with the rule id and event id, plus an output for relationship changes and memories and usually a log line.
- Follow-up events carry `:cause` (the id of the event that produced them). A dispatch processes at most 4 generations and, by default, the larger of 32 events or 4 per character; anything beyond is dropped and explained in the log and trace.
- Rules are pure. They never read the wall clock, use randomness, or perform I/O. The same state and event always produce the same result.

## Bounds

| Value | Range |
| --- | --- |
| character `loneliness`, `jealousy`, `joy`, `stress`, `energy` | 0..100 |
| relationship `affinity`, `trust`, `tension` | -100..100 |
| memory `importance`, `strength` | 0..100 |

Outputs report the delta that was actually applied after clamping.

## Event rules

### `gift_received` -> `gift`, `observation`

**gift** - the receiver:

- affinity toward the giver +10
- joy +20, loneliness -10
- remembers the gift (importance 60, kind `:experienced`)

**observation** - for each observer (the giver and receiver are never observers):

- remembers what they saw (importance 60, kind `:observed`, same topic as the gift)
- if they care about the giver (affinity >= 30): jealousy +10 (`:sensitive` +5, `:calm` -5) and tension toward the receiver +8

### `message_sent` -> `message`, `reply`

**message** - effects on the receiver, by the event's structured `tone`. Rules never parse the text.

| tone | receiver effects | remembered (importance) |
| --- | --- | --- |
| `warm` | affinity +4, trust +2, loneliness -8, joy +8 | yes (45) |
| `neutral` | loneliness -4 | no |
| `cold` | affinity -3, tension +4, joy -5 | yes (35) |
| `hostile` | affinity -8, trust -6, tension +10, stress +20, joy -10 | yes (65) |

History changes how a message lands, through impressions built by consolidation:

- **Goodwill** - if the receiver holds impressions of at least 3 kind acts from the sender (warm messages, gifts, comfort, time together), cold and hostile effects are halved (`goodwill_count`, `goodwill_percent`). Their reply reflects it: "That's not like you. Is something wrong?"
- **Wariness** - if the receiver holds an impression of at least 2 hostile messages from the sender, warm effects are halved (`wariness_count`, `wariness_percent`).

**reply** - when someone outside the cast (such as the user) talks to an active, unblocked character, the character emits a `:reply` output phrased from their current mood and memories. Replies do not change state.

### `apology_offered` -> `apology`

The receiver: jealousy -15, loneliness -6, stress -10, trust toward the apologizer +8, tension toward the apologizer -10 (never below 0), remembers the apology (importance 70).

### `time_tick` -> `time_passage`, `memory_decay`, `consolidation`, `autonomy`, `companionship`

**time_passage** - advances `state.clock` by `hours`. For each active character, per hour: loneliness +4, joy -2, stress -2. Tension in every relationship eases by 2 for each simulated day boundary crossed (so the result does not depend on tick size). Jealousy does not fade with time alone; it takes an apology or comfort.

**memory_decay** - recomputes each memory's strength from its age:

```txt
strength = importance - div(age_hours * (100 - importance), 96)
```

A memory loses `(100 - importance) / 4` strength per simulated day, independent of how time was split into ticks. Memories below strength 20 are *faded*: kept for inspection, excluded from context selection. After 30 simulated days faded (`forget_after_hours`), a memory is forgotten and removed, so long-running worlds do not grow without bound; impressions keep the patterns.

| importance | fades after |
| --- | --- |
| 45 (warm message) | ~2 days |
| 60 (gift) | 4 days |
| 70 (apology) | ~6.8 days |
| 90 | 4 weeks |
| 100 | never |

**consolidation** - individual memories fade, patterns should not. When a character holds at least 2 faded, unconsolidated firsthand memories of the same kind of interaction with the same actor (gifts, warm/cold/hostile messages, apologies, comfort, time together), they fold into an `:impression` memory such as `"user has been warm to mina 3 times."`. Importance is `40 + 10 * count`, capped at 90. An impression dates from when its latest memory faded (so the result does not depend on how time was split into ticks) and decays four times more slowly than ordinary memories (`memory_decay.impression_slowdown`), so patterns outlast the details. Later faded memories of the same pattern deepen the impression in place; the originals are kept and marked `consolidated_into`. Impressions are private: they are never gossiped. A faded impression no longer counts toward goodwill or wariness.

**autonomy** - characters act on their own. A character who is struggling (mood `jealous`, `lonely`, or `upset`) or `:talkative` confides a notable memory to their most trusted friend (trust >= 30) who has not heard about it yet:

- firsthand memories with importance >= 60
- talkative characters also retell `:heard` memories with importance >= 30

At most one confidence per character per tick. It is enqueued as a `gossip_shared` follow-up event.

**companionship** - a character whose mood is `lonely` invites the friend they like most (affinity >= 30) who can act, at most once per 12 simulated hours per pair; each character joins at most one outing per tick. Enqueued as `time_spent_together`.

### `time_spent_together` -> `together`

Both characters: loneliness -15, joy +6, affinity toward each other +2, and both remember it (importance 40). Emits a `:character_interaction` scene of kind `:together`. Repeated outings consolidate into impressions and count as kindness for goodwill.

### `gossip_shared` -> `gossip`, `empathy`

**gossip** - the listener gains a `:heard` memory of the same topic with importance reduced by 15 (minimum 20) and `source` set to the teller. The teller's loneliness -4 and trust toward the listener +2. If the listener already knew, nothing changes. Emits a `:character_interaction` scene.

Because each retelling loses importance and retelling needs importance >= 30, a rumor starting from an importance-60 observation travels at most three hops: 60 -> 45 -> 30 -> 20.

**empathy** - if the listener cares about the teller (affinity >= 25), the teller is struggling, and the listener is not, the listener offers comfort: a `comfort_offered` follow-up event, at most once per 12 simulated hours per pair.

### `comfort_offered` -> `comfort`

The receiver: loneliness -12, jealousy -5, stress -10, trust +5, affinity +3, and tension -5 (never below 0) toward the comforter, remembers being comforted (importance 55). Emits a `:character_interaction` scene when the comforter is a character.

## Reactive rules

These run after every event, whatever caused it.

### `mood`

Derives mood from numbers, first match wins:

| mood | condition |
| --- | --- |
| `upset` | stress >= 40 |
| `jealous` | jealousy >= 15 |
| `lonely` | loneliness >= 50 |
| `happy` | joy >= 20 |
| `neutral` | otherwise |

Emits `:mood_changed` when a mood changes.

### `proactive`

Characters reach out to people (actors who are not characters, such as `user`) when pressure crosses a threshold. Jealousy goes to whoever gave the gift they saw, loneliness to the person they feel closest to, and curiosity to the person the news is about; a world with no relationships to people addresses `user`. At most one proactive message per character per event; the first matching reason wins.

| reason | condition | cooldown |
| --- | --- | --- |
| `jealous` | jealousy >= 15 and jealousy + loneliness >= 45 | 24 simulated hours |
| `lonely` | loneliness >= 60 and jealousy < 15 | 24 simulated hours |
| `curious` | holds secondhand news involving the user, and is `:playful` or has affinity >= 30 toward the user | once per topic |

Characters do not reach out to someone they feel tense toward (tension >= 10, parameter `avoid_tension`); they confide in friends instead.

Each message carries fallback text from deterministic templates, the ids of the memories it references, and a read-only context snapshot for optional LLM rendering (see [expression.md](expression.md)).

## Tuning

Every rule parameter printed by `mix aethrion.rules` (all the per-rule numbers on this page, including the message tone effects) has a default that a world can override. The faded threshold (20) is fixed, and the cascade limits are dispatch options (`max_depth`, `max_events`) rather than tuning. A world can override any of them without code, so two worlds can run the same rules with a different temperament:

```elixir
state =
  state
  |> Aethrion.Tuning.put(:autonomy, :trust_threshold, 15)   # confide in acquaintances too
  |> Aethrion.Tuning.put(:gossip, :importance_drop, 10)     # retellings keep more weight
```

The same in a scenario or a saved state:

```json
"tuning": {"autonomy": {"trust_threshold": 15}, "gossip": {"importance_drop": 10}}
```

Only parameters a rule declares are accepted. Memory importance and strength stay within 0..100 whatever the tuning. Tuning for custom rules is kept when the world is loaded with the same pipeline (`State.parse(data, pipeline: p)`, `JsonFile.load(path: ..., pipeline: p)`, `Scenario.load(path, pipeline: p)`; a `RuntimeServer` passes its own pipeline). `mix aethrion.rules` prints every parameter and its default, and `Aethrion.Tuning.describe/2` returns defaults alongside a world's current values. The bundled `06_small_town.json` scenario shows the effect: with default tuning nothing spreads in that world; tuned, one witnessed gift reaches the end of the street.

## Writing your own rule

```elixir
defmodule MyGame.Rules.Rivalry do
  use Aethrion.Rule,
    id: :rivalry,
    description: "Rivals grow tense when the other receives a gift.",
    params: [tension_delta: 5]

  alias Aethrion.Transition

  @impl true
  def apply(%Transition{event: event} = transition) do
    case MyGame.rival_of(event.to) do
      nil ->
        transition

      rival ->
        delta = Transition.param(transition, :tension_delta)
        Transition.adjust_relationship(transition, rival, event.to, :tension, delta)
    end
  end
end

pipeline = Aethrion.Pipeline.append(Aethrion.Pipeline.default(), :gift_received, MyGame.Rules.Rivalry)
Aethrion.dispatch(state, event, pipeline: pipeline)
```

Custom event types work the same way: register rules for a new type with `Pipeline.append/3` and dispatch maps with that `:type`. Built-in validation only applies to built-in types; validate custom events in your rules.

Useful `Aethrion.Transition` helpers:

| helper | effect |
| --- | --- |
| `adjust_character/5` | add to a numeric character field, clamped, logged, traced |
| `set_character/4` | set a non-numeric field such as `last_active_at` |
| `adjust_relationship/6` | add to affinity, trust, or tension; emits `:relationship_changed` |
| `remember/2` | store a memory; emits `:memory_created` |
| `update_memory/4` | change an existing memory, traced |
| `emit/2` | emit any output, tagged with rule and event |
| `note/3` | record a decision that changed nothing |
| `enqueue/2` | add a follow-up event |
| `cooldown_ready?/3`, `put_cooldown/2` | rate-limit behavior in simulated hours |
| `param/2` | read one of the rule's declared parameters, honoring the world's tuning |
