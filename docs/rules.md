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
  -> reactive rules (mood, proactive, bond), for every event
  -> follow-up events enqueued by rules, breadth-first,
     each validated and run through the same pipeline
```

- Rules are modules implementing `Aethrion.Rule` (`id/0`, `description/0`, `params/0`, `apply/1`); `use Aethrion.Rule` defines the first three.
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

Outputs report the delta that was actually applied after clamping. `energy` is reserved for hosts: no built-in rule reads or changes it, but it is validated, persisted, and available to custom rules.

## Event rules

### `gift_received` -> `gift`, `reply`, `observation`

**gift** - the receiver:

- affinity toward the giver +10
- joy +20, loneliness -10, jealousy -10 (someone thought of them)
- remembers the gift (importance 60, kind `:experienced`)

**reply** - a gift from someone outside the cast gets a reply with tone `:gift`: "Thank you for the tea!", "You didn't have to! I love it." from a close friend, "For me? ...I thought you'd forgotten about me." from someone who felt left out by the giver since their last gift or apology from them, "Another one? You're spoiling me." after several, and "...Thanks. I don't know what to say." with hurt feelings between them.

**observation** - for each observer (the giver and receiver are never observers, and inactive or blocked characters see nothing):

- remembers what they saw (importance 60, kind `:observed`, same topic as the gift)
- if they care about the giver (affinity >= 30): jealousy +10 (`:sensitive` +5, `:calm` -5) and tension toward the receiver +8, once a day per giver (a second gift the same day is noticed, not felt again), and not at all if the giver gave them something in the last day

### `message_sent` -> `message`, `reply`, `reputation`

**message** - effects on the receiver, by the event's structured `tone`. Rules never parse the text.

| tone | receiver effects | remembered (importance) |
| --- | --- | --- |
| `warm` | affinity +4, trust +2, loneliness -15 (or half of it, if more, after a quiet stretch), joy +8, tension -2 (not below 0) | yes (45) |
| `neutral` | loneliness -6 | no |
| `cold` | affinity -3, tension +4, joy -5 | yes (35) |
| `hostile` | affinity -8, trust -6, tension +10, stress +20, joy -10 | yes (65) |

History changes how a message lands, through impressions built by consolidation:

- **Goodwill** - if the receiver holds impressions of at least 3 kind acts from the sender (warm messages, gifts, comfort, time together), and more kind acts than hostile messages (remembered ones, this one included, and impressions alike), cold and hostile effects are halved (`goodwill_count`, `goodwill_percent`). Their reply reflects it: "That's not like you. Is something wrong?" (to cold words, "Oh... okay. Is everything alright?") A cycle of kindness and insults runs out of goodwill.
- **Wariness** - if the receiver holds an impression of at least 2 hostile messages from the sender, warm effects are halved (`wariness_count`, `wariness_percent`).
- **Reputation** - only when the receiver holds no firsthand impression of the sender at all, what they have seen or heard counts, and for less: a reputation for hostility to others (2+) leaves 75% of a warm message's effect, and a reputation for warmth to others (3+) leaves 75% of a cold or hostile one's (`reputation_*` params). Any firsthand history takes precedence.

**reply** - when someone outside the cast (such as the user) talks to an active, unblocked character, the character emits a `:reply` output phrased from their mood and memories: harsh words are answered from the hurt they cause, anything else from the mood it found. Replies do not change state. A warm message from someone the character saw or heard be hostile to another character gets a pointed answer: "Thanks... but I saw what you said to Mina." Hurt feelings speak before the mood: with a strained or estranged bond the bond answers ("...What do you want?"), and with tension of 10 or more a warm word gets "Thanks... I'm still a little hurt, though." A character remembers when each person last talked to them; after 72 simulated hours or more, warm and neutral replies say so ("You're back! It's been a while." or, if lonely, "You're back... I missed you."). When the character's mood is neutral or happy, the bond colors warm and neutral replies: a close friend says "You always know how to make my day." Every reply weighs the whole record: every harsh message the character still remembers from the sender, the sender's apologies, and what they make of the sender, so goodwill in the reply matches goodwill in the rule. Kind words the day after an insult, with no apology since, are met warily. Replies vary with how often the person has said something similar lately, so the same kindness does not get the same line twice in a row, and repeated harsh words escalate. Cold and hostile messages are counted separately, over the last four days (details already faded included), and kind words in between do not reset the count: the second hostile message gets "Again? What is going on with you?" (or "Please stop." if it has left them upset), the second cold one "You've been short with me lately.", the third hostile one "I'm not doing this with you anymore.", and from the fourth of either, or the second while estranged, the character stops answering ("...").

**reputation** - characters judge people by how they treat others. For each witness in the message's (or apology's, see below) `observed_by` (never the sender or receiver, and never an inactive or blocked character):

- remembers a warm, cold, or hostile message (importance 40, 35, 60; kind `:observed`, same topic as the receiver's memory). Neutral messages are not remembered.
- if they care about the receiver (affinity >= 20), their relationship with the sender changes:

| tone | witness toward sender |
| --- | --- |
| `warm` | affinity +2, trust +1 |
| `cold` | trust -2, tension +2 |
| `hostile` | trust -4, tension +4 |

What a character only sees or hears raises affinity and trust no higher than 60 (`goodwill_cap`); past that, it takes dealing with the person yourself. When several witnesses speak up about the same incident, each says it differently.

### `apology_offered` -> `apology`, `reply`, `reputation`

The receiver: jealousy -15, loneliness -6, stress -10, trust toward the apologizer +8, tension toward the apologizer -10 (never below 0), remembers the apology (importance 70). Apologies wear thin: for each earlier apology from the same person the receiver still remembers (about a week), the trust gained and the tension eased are halved.

The receiver replies (a `:reply` with tone `:apology`): gratefully the first time, "Okay... Just please don't make a habit of it." the second, and "You keep saying sorry. I just need it to stop happening." after that. A character who felt left out by a gift says "Thanks. I just wanted to feel remembered too.", one with nothing to forgive "You don't have to apologize. We're okay.", and one still tense "Thank you for saying that. I need a little time."

Apologies take `observed_by` too. Witnesses remember it (importance 45), and those who care about the receiver (affinity >= 20) trust the apologizer +2 and ease tension toward them by 3 (never below 0); hearing about it through gossip counts for half. Making amends in public repairs a reputation, and a character who saw the apology no longer brings up the harsh words in replies.

### `time_tick` -> `time_passage`, `memory_decay`, `consolidation`, `autonomy`, `companionship`

**time_passage** - advances `state.clock` by `hours`. For each active character, per hour: joy -2, stress -2, and loneliness +2 for each hour 16 or more (`quiet_hours`) after they last had company. Anything that eases a character's loneliness (a warm or neutral message, a gift, an apology, comfort, gossip, time together) counts as company; a character who has never had company grows lonely from the start. For each simulated day boundary crossed, jealousy fades by 5 and tension in every relationship eases by 2. None of this depends on how time was split into ticks.

**memory_decay** - recomputes each memory's strength from its age:

```txt
strength = importance - div(age_hours * (100 - importance), 96)
```

A memory loses `(100 - importance) / 4` strength per simulated day, independent of how time was split into ticks. Memories below strength 20 are *faded*: kept for inspection, excluded from context selection. After 30 simulated days faded (`forget_after_hours`), a memory is forgotten and removed, so long-running worlds do not grow without bound; impressions keep the patterns. Impressions themselves are never forgotten, and a memory that could become part of a pattern is forgotten only once it has been consolidated into one.

| importance | fades after |
| --- | --- |
| 45 (warm message) | ~2 days |
| 60 (gift) | 4 days |
| 70 (apology) | ~6.8 days |
| 90 | 4 weeks |
| 100 | never |

**consolidation** - individual memories fade, patterns should not. When a character holds at least 2 faded, unconsolidated firsthand memories of the same kind of interaction with the same actor (gifts, warm/cold/hostile messages, apologies, comfort, time together), they fold into an `:impression` memory such as `"user has been warm to mina 3 times."`. Importance is `40 + 10 * count`, capped at 90. An impression dates from when its latest memory faded (so the result does not depend on how time was split into ticks) and decays four times more slowly than ordinary memories (`memory_decay.impression_slowdown`), so patterns outlast the details. Later faded memories of the same pattern deepen the impression in place; the originals are kept and marked `consolidated_into`. Impressions are private: they are never gossiped. A faded impression no longer counts toward goodwill or wariness.

Secondhand memories fold too. Faded `:observed` and `:heard` memories of how an actor *talked to* other characters (warm, cold, or hostile messages) become a reputation impression, grouped by pattern and actor across everyone they treated that way: `"haru knows user has been hostile to mina and yuna 2 times."` (id `memory:haru:reputation:hostile:user`). Memories of something done to or by the holder are never reputation, and neither are sightings of gifts (they make observers jealous instead). Every impression records the topics it folded in, so each event counts once.

**autonomy** - characters act on their own. A character who is struggling (mood `jealous`, `lonely`, or `upset`) or `:talkative` confides a notable memory to their most trusted friend (trust >= 30) who has not heard about it yet:

- firsthand memories with importance >= 60
- talkative characters also retell `:heard` memories with importance >= 30

At most one confidence per character per tick, and never harsh words the teller knows were apologized for. It is enqueued as a `gossip_shared` follow-up event.

**companionship** - a character whose mood is `lonely` invites the friend they like most (affinity >= 30) who can act, at most once per 12 simulated hours per pair; each character joins at most one outing per tick. Enqueued as `time_spent_together`.

### `time_spent_together` -> `together`

Both characters: loneliness -25, joy +6, affinity toward each other +2 (up to 60: past that, afternoons are comfortable rather than ever closer), and both remember it (importance 40). Emits a `:character_interaction` scene of kind `:together`, which varies from day to day (a quiet afternoon, a long walk, dinner, sitting together). Repeated outings consolidate into impressions and count as kindness for goodwill.

### `gossip_shared` -> `gossip`, `reputation`, `empathy`

**gossip** - the listener gains a `:heard` memory of the same topic with importance reduced by 15 (minimum 20) and `source` set to the teller. The teller's loneliness -4 and trust toward the listener +2. If the listener already knew, nothing changes. Emits a `:character_interaction` scene.

Because each retelling loses importance and retelling needs importance >= 30, a rumor starting from an importance-60 observation travels at most three hops: 60 -> 45 -> 30 -> 20.

**reputation** - if what the listener just heard is how someone treated a character the listener cares about (affinity >= 20), the listener judges them as a witness would, at half the effect (`heard_percent`, rounded toward zero: hostile hearsay is trust -2 and tension +2, cold is trust -1 and tension +1, warm is affinity +1). Nobody judges a message they sent or received, and nobody judges the same message twice: a story whose details a character has forgotten is still known through the impression it folded into.

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

### `bond`

Names what a directed relationship has become, first match wins:

| bond | condition |
| --- | --- |
| `estranged` | tension >= 50 or affinity <= -30 |
| `strained` | tension >= 20 or trust <= -10 |
| `close` | affinity >= 50, trust >= 30, and tension < 10 |
| `friendly` | affinity >= 25, trust >= 15, and tension < 10 |
| `neutral` | otherwise |

Bonds settle rather than flicker: once a relationship has a bond (recorded on the relationship as `bond`), it keeps it until the numbers move 5 points (`hysteresis`) past the threshold that would change it. A close friend stays close until affinity drops below 45; a strained relationship stays strained until tension falls below 15. Getting worse into strained or estranged, and getting closer, register at once. `Aethrion.Rules.Bond.derive/2` gives the current bond of any relationship. After each event, every relationship the event changed is compared before and after; when its bond moved, the rule emits `:bond_changed` and logs `[Bond] Mina toward user: friendly -> strained`. Relationships an event did not touch never announce. Bonds appear in the CLI status table, reports, and expression requests.

### `proactive`

Characters reach out to people (actors who are not characters, such as `user`) when pressure crosses a threshold. Jealousy goes to whoever gave the gift they saw, loneliness to the person they feel closest to, and curiosity to the person the news is about; a world with no relationships to people addresses `user`. A character sends at most one proactive message per simulated hour (`min_gap_hours`); the first matching reason wins.

| reason | condition | cooldown |
| --- | --- | --- |
| `jealous` | jealousy >= 15 and jealousy + loneliness >= 45 | 24 simulated hours |
| `protective` | saw a person be hostile to a character they care about (affinity >= 30), and has not seen or heard them apologize since | once per incident, and 24 simulated hours per person and friend |
| `lonely` | loneliness >= 60, jealousy < 15, affinity >= 25 toward the person, no company and nothing from that person for 6 hours, and not heading out with a friend this hour | 24 simulated hours; 72 after a lonely message that got no reply; a week after a week of silence |
| `curious` | holds secondhand news involving a person (not a character), and is `:playful` or has affinity >= 30 toward them; not about harsh words from someone they saw be hostile themselves | once per topic |

Characters do not reach out to someone they feel tense toward (tension >= 5, parameter `avoid_tension`: one hostile message keeps them away for about three days); they confide in friends instead; speaking up for a friend is the exception. Writing again after a lonely message got no reply costs 2 affinity toward that person. Lonely messages quote each kind word once, and recall fond memories (kind words, a gift from the last three days, a record of kindness) only when nothing harsh stands between them, and mention how long it has been; after a week of silence only the silence is left: "I guess you've been busy. I'll be here whenever you want to talk."

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
