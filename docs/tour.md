# A Tour Of Aethrion

[한국어](tour.ko.md)

What the rules do, shown with real output: characters who see, confide, gossip, and comfort each other, reputations that outlast the details, and the tools to ask why.

## Run It

None of this needs a model:

```bash
mix deps.get
mix demo.drama                 # two host events and everything they cascade into
mix demo.interactive           # talk to the characters, ask why they feel what they feel (--no-status for less output)
mix aethrion.scenario --all    # run the bundled scenarios and check their expectations
mix aethrion.report priv/scenarios/01_the_flower.json   # HTML report in tmp/
```

New here? The [tutorial](tutorial.md) builds a world, a rule, and a what-if in a few minutes. A recorded session of the interactive demo (real output, [plain-text transcript](../assets/demo/interactive-demo.txt)):

![Aethrion interactive demo](../assets/demo/interactive-demo-readable.svg)

With a real model (optional; the simulation is identical without one): `ANTHROPIC_API_KEY=... mix demo.interactive --llm anthropic`.

## Two Events In, A Story Out

The host sends two events: the user gives Mina a flower while Yuna watches, and two hours pass. Nothing else is scripted. Output of `mix demo.drama`, abridged:

```txt
EVENT    user gives Mina a flower (seen by Yuna)
RELATION Mina affinity toward user +10
MEMORY   Mina remembers: "user gave mina a flower."
SAYS     Mina -> user: "Thank you for the flower!"
RULE     Yuna noticed the gift to Mina
STATE    Yuna jealousy +15
MEMORY   Yuna remembers: "yuna saw user give mina a flower."
MOOD     Yuna neutral -> jealous

EVENT    time passes +2h
SAYS     Yuna -> user: "You looked happy with Mina earlier. I wondered if you forgot about me."
CASCADE  Yuna confides in Haru
MEMORY   Haru remembers: "yuna told haru: yuna saw user give mina a flower."
SCENE    Yuna tells Haru about the flower you gave Mina.
SAYS     Haru -> user: "Yuna told me you gave Mina a flower. Smooth."
CASCADE  Haru comforts Yuna
STATE    Yuna loneliness -12
STATE    Yuna jealousy -5
SCENE    Haru stays with Yuna for a while. Yuna feels a little lighter.
MOOD     Yuna jealous -> neutral
```

Yuna reaches out because jealousy plus loneliness crossed a threshold. Yuna confides in Haru because she is struggling and trusts Haru most. Haru hears about the flower secondhand and, being playful, teases the user. Haru comforts Yuna out of care for her. Each of those is a rule you can read, test, and trace.

Apologize to Yuna before the two hours pass and none of it happens. `mix demo.branches` plays the same moment four ways (say nothing, apologize, kind words, snap) and compares where Yuna ends up.

## Word Gets Around

How you treat one character reaches the others. The user snaps at Mina while Haru is in the room, then is friendly to Haru the next day (`priv/scenarios/12_word_gets_around.json`, abridged):

```txt
EVENT    user -> Mina (hostile): You always ruin everything. (seen by Haru)
SAYS     Mina -> user: "Please stop."
RULE     Haru saw user be hostile to Mina and trusts user less
SAYS     Haru -> user: "What you said to Mina was unkind. Is everything okay?"

EVENT    time passes +2h
CASCADE  Mina confides in Yuna
RULE     Yuna heard user be hostile to Mina and trusts user less
SAYS     Yuna -> user: "Mina told me what you said. That didn't sound like you. Is everything okay?"
CASCADE  Yuna comforts Mina

EVENT    user -> Haru (warm): Want to grab lunch tomorrow?
SAYS     Haru -> user: "Thanks... but I saw what you said to Mina."
```

Haru saw it and cares about Mina, so Haru trusts the user less and says so. Yuna only heard about it, so Yuna's trust drops by half as much. Do it again and, once the details fade, what is left is a reputation ("haru knows user has been hostile to mina and yuna 2 times.") that blunts the user's kindness for weeks. In `mix demo.interactive`, try `here haru` and then `message user yuna hostile leave me alone` (Haru cares about Yuna), followed by `opinion haru user`. Relationships also have names that change along the way (friendly, strained, close, ...), announced as events; `why <from>-><to> bond` shows when and why one changed.

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

The target use case is a social simulation layer for narrative agents: games, TRPG assistants, visual-novel-like character systems, or long-running AI companion apps.

Facts like "Yuna saw the gift", "Haru heard about it from Yuna", or "Yuna's trust changed after an apology" should be inspectable, testable, persistent rule outcomes, not facts improvised by an LLM every time.

## How It Works

```txt
host event
  -> validate
  -> rule pipeline (event rules, then reactive rules)
  -> follow-up events enqueued by rules, validated and run through the same pipeline
  -> state + structured outputs + trace
  -> optional: an LLM phrases expressive outputs from read-only snapshots
```

- **Rules** are small modules (`use Aethrion.Rule`) organized by an explicit `Aethrion.Pipeline`. Add your own, remove built-ins, or register new event types. `mix aethrion.rules` lists them.
- **Cascades** let characters act on each other: observation, confiding, rumor, empathy, comfort, companionship.
- **Reputation** carries how you treat one character to the others: whoever sees or hears about it judges you, and faded details become a lasting reputation.
- **Bonds** name what each relationship has become (strained, friendly, close, ...) and announce when an event changes one.
- **Time** behaves like time with people: characters grow lonely after a quiet stretch, reach out, and stop writing when nobody answers; jealousy fades; apologies wear thin when repeated; replies vary instead of repeating. Week-long played sessions check that the lines stay plausible.
- **Several people** can share a world: players have display names, each gets their own "while you were away" digest, and characters address the person their feelings are about.
- **Traces** record every change: which rule, which event, before and after. `why yuna jealousy` in the interactive demo answers "why is Yuna this jealous?" with each change and the chain of events behind it.
- **Memory** has kinds (experienced, observed, heard), sources, topics that link everyone's memory of the same event, age-based decay, and consolidation of faded experiences into lasting impressions. Retrieval is deterministic; no vector search.
- **Tuning** makes every rule's numbers data: a world, saved state, or scenario can override them without code.
- **Determinism** makes it testable: the same events always produce the same world. Property tests check bounds, determinism, and persistence round trips on random event sequences.

See [docs/rules.md](rules.md) for every rule and number.

## Scenarios And Reports

Scenarios are JSON files with a world, a script of events, and expectations. They run in the test suite and render as self-contained HTML reports.

```json
{
  "name": "The flower",
  "world": "demo",
  "events": [
    {"type": "gift_received", "from": "user", "to": "mina", "item": "flower", "observed_by": ["yuna"]},
    {"type": "time_tick", "hours": 2}
  ],
  "expect": [
    {"output": "character_interaction", "kind": "comfort", "character": "haru", "to": "yuna", "count": 1},
    {"memory": {"character": "haru", "kind": "heard", "source": "yuna"}, "count": 1}
  ]
}
```

<img src="../assets/report/the-flower.png" alt="Aethrion scenario report: summary, cast, feelings over time, relationship graph, and timeline" width="720">

Bundled scenarios: the flower, the apology, words matter (tone), rumor mill (news spreading through a trust graph), long silence (loneliness and fading memory), small town (the same rules, tuned differently), crossroads (one moment, four branches, compared side by side), old friends (conversations fading into lasting impressions), benefit of the doubt (the same harsh words landing differently depending on history), company (friends keeping each other company while the user is away), two regulars (two people, each message going to the right one), word gets around (a harsh word in front of a friend becoming a reputation), slowly closer (a week of small kindnesses, bond by bond), and a Korean boarding house (best read as a Korean report: `mix aethrion.report ... --locale ko`). See [docs/scenarios.md](scenarios.md).

## Interactive Demo

```txt
user> gift user mina flower observed_by yuna
...
MOOD     Yuna neutral -> jealous

user> say yuna sorry I forgot about you
INTENT   "sorry I forgot about you" -> apology_offered via Aethrion.LLM.FakeAdapter
EVENT    user apologizes to Yuna: sorry I forgot about you
RULE     Yuna accepted an apology from user
STATE    Yuna jealousy -15
STATE    Yuna loneliness -6
RELATION Yuna trust toward user +8
MEMORY   Yuna remembers: "user apologized to yuna: sorry I forgot about you"
SAYS     Yuna -> user: "Thanks. I just wanted to feel remembered too."
MOOD     Yuna jealous -> neutral

user> why yuna jealousy
  jealousy 0 -> 15 by observation in e1: user gives Mina a flower (seen by Yuna)
  jealousy 15 -> 0 by apology in e2: user apologizes to Yuna: sorry I forgot about you

user> context yuna
  Speaker: Yuna (Sensitive, observant, and afraid of being forgotten; voice: Quiet and careful; short, hesitant sentences, trailing off with ellipses; traits: observant, sensitive; mood: neutral)
  Speaker toward listener: friendly; affinity 38, trust 28, tension 0 (scale -100..100)
  People: mina = Mina, user = you, yuna = Yuna
  Memories:
  - user apologized to yuna: sorry I forgot about you (experienced, importance 70, just now)
  - yuna saw user give mina a flower. (observed, importance 60, just now)
  Recent conversation (oldest first):
  - you: (apologizes) "sorry I forgot about you"
  - Yuna: "Thanks. I just wanted to feel remembered too."
  Draft line: "It's been quiet today. Do you have a minute to talk?"
```

Commands include `say`, `message`, `gift`, `apologize`, `comfort`, `tick`, `here` (who else is in the room, witnessing what you say), `opinion` (how one character sees another), `digest` (what changed while you weren't looking), `status`, `memories`, `why`, `context`, `timeline`, `rules`, `undo`, `save`, `load`, `record` (turn a play session into a replayable scenario), and `report` (the session as an HTML report).
