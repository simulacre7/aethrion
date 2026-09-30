# Scenarios

A scenario is a JSON file with a world, a script of events, and expectations. Scenarios make social behavior reviewable and testable without writing Elixir, and they are how Aethrion's own behavior is specified: every bundled scenario runs in the test suite.

```bash
mix aethrion.scenario priv/scenarios/01_the_flower.json   # run and check
mix aethrion.scenario --all --quiet                       # check every bundled scenario
mix aethrion.scenario my.json --json                      # machine-readable result
mix aethrion.report priv/scenarios/01_the_flower.json     # HTML report in tmp/
mix aethrion.report priv/scenarios/01_the_flower.json --locale ko   # character lines in Korean
```

## Bundled scenarios

| File | What it shows |
| --- | --- |
| `01_the_flower.json` | Two host events cascade into a proactive message, a confidence, a tease, and comfort. |
| `02_the_apology.json` | The same gift, followed by an apology: jealousy resolves and nothing cascades. |
| `03_words_matter.json` | Hostile messages upset Mina; an apology and warm words repair some, not all, of the damage. |
| `04_rumor_mill.json` | A custom world where one witnessed gift travels three hops along lines of trust and dies out. |
| `05_long_silence.json` | Days without contact: lonely messages quote kind words while remembered, then the memory fades. |
| `06_small_town.json` | The rumor mill's rules with small-town tuning: news spreads through acquaintances and travels four hops. |
| `07_crossroads.json` | One moment, four branches: say nothing, apologize, kind words, or snap. Compared side by side in the report. |
| `08_old_friends.json` | Days of kindness, then silence, in a world tuned for days: conversations fade into lasting impressions, and the impression is what Mina remembers. |
| `09_benefit_of_the_doubt.json` | The same hostile words land at half strength on a friend with a record of kindness, and in full on someone without one. |
| `10_company.json` | Three quiet days: friends keep each other company while the character without a close friend grows loneliest. |
| `11_two_regulars.json` | Two people visit the same characters: each message goes to the person it is about or the one the character feels closest to. |
| `12_word_gets_around.json` | The user snaps at Mina in front of Haru; Haru and, through Mina, Yuna trust the user less. Repeat it and a reputation forms; apologize in public and their trust comes back. |
| `13_slowly_closer.json` | A week of small kindnesses moves Haru's bond with the user from neutral to friendly to close; one harsh word lands at half strength but still slips it back to friendly. |

## Format

A JSON Schema for editor completion and validation ships at `priv/scenario.schema.json`. Point a scenario at it with `"$schema"`:

```json
{"$schema": "../scenario.schema.json", "name": "..."}
```

```json
{
  "name": "The flower",
  "description": "What this scenario demonstrates.",
  "world": "demo",
  "events": [
    {"type": "gift_received", "from": "user", "to": "mina", "item": "flower", "observed_by": ["yuna"], "at": "day1:10:00"},
    {"type": "time_tick", "now": "day1:12:00", "hours": 2}
  ],
  "expect": [
    {"character": "yuna", "field": "mood", "equals": "neutral"}
  ]
}
```

### World

Either `"demo"` (Mina, Yuna, Haru) or an object in the persistence format:

```json
{
  "characters": [
    {"id": "ari", "name": "Ari", "profile": "Notices everything.", "traits": ["talkative"],
     "state": {"loneliness": 10}}
  ],
  "relationships": [
    {"from": "ari", "to": "bo", "affinity": 30, "trust": 60, "tension": 0}
  ]
}
```

Unknown moods and memory kinds fall back to defaults, so untrusted files cannot create atoms. Traits are open-ended.

### Tuning

An optional `tuning` object overrides rule parameters for this world. Unknown rules or parameters are rejected. See [rules.md](rules.md#tuning).

```json
"tuning": {"autonomy": {"trust_threshold": 15}, "gossip": {"importance_drop": 10}}
```

### Events

| type | fields |
| --- | --- |
| `gift_received` | `from`, `to`, `item`, `observed_by`, `at` |
| `message_sent` | `from`, `to`, `text`, `tone` (`warm`, `neutral`, `cold`, `hostile`), `observed_by`, `at` |
| `apology_offered` | `from`, `to`, `reason`, `observed_by`, `at` |
| `time_tick` | `hours`, `now` |
| `gossip_shared` | `from`, `to`, `memory_id`, `at` |
| `comfort_offered` | `from`, `to`, `at` |
| `time_spent_together` | `from`, `to`, `at` |

Events are validated when they run. A rejected event stops the scenario and reports its index.

Custom event types registered in a pipeline can be used too: load and run the scenario with the same pipeline (`Scenario.load(path, pipeline: p)` and `Scenario.run(scenario, pipeline: p)`). Their fields become atom keys only when the atom already exists, so untrusted files cannot create atoms; keep custom field values JSON-native (strings, numbers, booleans, lists, maps) so they replay exactly.

### Branches

After the shared `events`, a scenario may define alternative futures. Each branch starts from the state after the shared events; its expectations are checked against its own final state and the outputs produced after the split.

```json
"branches": [
  {"name": "Say nothing", "events": [{"type": "time_tick", "hours": 2}],
   "expect": [{"output": "proactive_message", "character": "yuna", "count": 1}]},
  {"name": "Apologize",
   "events": [{"type": "apology_offered", "from": "user", "to": "yuna", "reason": "sorry"},
              {"type": "time_tick", "hours": 2}],
   "expect": [{"output": "proactive_message", "count": 0}]}
]
```

The HTML report adds a comparison table (values that differ between branches first, identical ones folded away) and each branch's timeline.

### Expectations

Each expectation selects a value and compares it with `equals`, `at_least`, or `at_most`.

| selector | value |
| --- | --- |
| `{"character": id, "field": name}` | a character state field: `mood`, `loneliness`, `jealousy`, `joy`, `stress`, `energy`, `active`, `blocked` |
| `{"relationship": [from, to], "field": name}` | `affinity`, `trust`, `tension`, or `bond` (for example `{"equals": "close"}`) |
| `{"output": type, ...filters}` | the number of outputs of that type matching every filter (`character` for the speaking or acting character, `reason`, `kind`, `to`, `before`, `after`, `text`, `tone`; `relationship_changed` and `bond_changed` use `from` and `to`) |
| `{"memory": {...filters}}` | the number of memories matching every filter (`character`, `kind`, `source`, `importance`, `topic`, `content`, `faded`) |
| `{"clock": hours}` | the simulated clock |

Output and memory expectations without a comparison pass when at least one matches. `count` is shorthand for `equals` on the count.

```json
{"output": "proactive_message", "character": "yuna", "reason": "jealous", "count": 1}
{"memory": {"character": "haru", "kind": "heard", "source": "yuna"}, "count": 1}
{"relationship": ["yuna", "haru"], "field": "trust", "at_least": 45}
```

## Recording a session

Play in `mix demo.interactive`, then `record path.json`. The file contains the world you started from, every host event you sent (not the ones they cascaded into), and expectations that snapshot the outcome: each character's final mood and how many proactive messages and scenes each character produced. `mix aethrion.scenario path.json` replays it; if a rule change alters the story, the replay fails and shows what moved.

## From Elixir

```elixir
{:ok, scenario} = Aethrion.Scenario.load("priv/scenarios/01_the_flower.json")
{:ok, result} = Aethrion.Scenario.run(scenario)

Aethrion.Scenario.passed?(result)
result.steps     # one Aethrion.Step per host event, with trace
result.checks    # [%{description, passed?, actual}]

File.write!("report.html", Aethrion.Report.html(result))
```
