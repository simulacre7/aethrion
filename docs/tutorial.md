# Tutorial: a world of your own

This walks through [examples/tutorial_cafe.exs](../examples/tutorial_cafe.exs) step by step. By the end you will have built a small world, added your own rule, compared two futures, and rendered a report. Run the whole thing with:

```bash
mix run examples/tutorial_cafe.exs
```

## 1. Build a world

A world is plain data: characters and directed relationships.

```elixir
alias Aethrion.{Character, CharacterState, Event, Pipeline, Relationship, Runtime, State}

state =
  State.new(
    characters: [
      %Character{id: "sol", name: "Sol", profile: "Owner. Remembers every regular's order.", traits: [:calm]},
      %Character{id: "ivy", name: "Ivy", profile: "Barista. Loves attention from the regulars.", traits: [:sensitive]},
      %Character{id: "tae", name: "Tae", profile: "Weekend baker. Hears all the gossip.",
                 traits: [:talkative], state: %CharacterState{loneliness: 20}}
    ],
    relationships: [
      %Relationship{from: "ivy", to: "user", affinity: 35, trust: 20},
      %Relationship{from: "sol", to: "user", affinity: 25, trust: 30},
      %Relationship{from: "tae", to: "ivy", affinity: 30, trust: 45},
      %Relationship{from: "ivy", to: "tae", affinity: 30, trust: 40}
    ]
  )
```

A few details already matter:

- `traits` are read by rules. `:sensitive` makes Ivy more easily jealous, `:calm` makes Sol less so, and `:talkative` makes Tae pass news along.
- Relationships are directed. `ivy -> user` is how Ivy feels about the user; `user` is not a character, just an actor id.
- Ivy cares about the user (affinity 35 >= 30), so she will be jealous if she sees the user favor someone else. Ivy trusts Tae (40 >= 30), so she will confide in Tae when she is struggling.

## 2. Add a rule

Rules are modules. They receive a `Transition` and change state only through its helpers, so every change is traced. Numbers go in `params`, so a world can tune them without code.

```elixir
defmodule Cafe.Rules.Tip do
  use Aethrion.Rule,
    id: :tip,
    description: "A tip makes the barista feel appreciated and earns the owner's trust.",
    params: [joy_delta: 12, owner_trust: 3]

  alias Aethrion.Transition

  @impl true
  def apply(%Transition{event: event} = transition) do
    transition
    |> Transition.adjust_character(event.to, :joy, Transition.param(transition, :joy_delta))
    |> Transition.adjust_relationship("sol", event.from, :trust, Transition.param(transition, :owner_trust))
    |> Transition.note("#{Transition.name(transition, event.to)} got a tip from #{event.from}")
  end
end
```

Register it for a new event type. The built-in rules keep running, and the reactive rules (mood, proactive messages) run after your event too.

```elixir
pipeline = Pipeline.append(Pipeline.default(), :tip_left, Cafe.Rules.Tip)
run = fn state, events -> Runtime.run(state, events, pipeline: pipeline) end
```

## 3. Run a morning

```elixir
{:ok, morning, steps} =
  run.(state, [
    %{type: :tip_left, from: "user", to: "ivy"},
    Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"], at: "09:10"),
    Event.time_tick("11:00", hours: 2)
  ])

steps |> Enum.flat_map(& &1.log) |> Enum.each(&IO.puts/1)
```

Three host events come back as five processed events. The log shows why:

```txt
[State] Ivy joy +12
[Relation] Sol trust toward user +3
[Rule] Ivy got a tip from user
...
[Rule] Ivy noticed the gift to Sol
[State] Ivy jealousy +15
[Mood] Ivy neutral -> jealous
...
[Event] Ivy confides in Tae
[Scene] Ivy tells Tae about the pastry box you gave Sol.
[Event] Tae comforts Ivy
[Mood] Ivy jealous -> neutral
```

Nobody scripted the last four lines. Ivy was jealous, trusted Tae, and confided; Tae cared about Ivy and comforted her. Each `step.trace` records which rule made every change, from what value to what value.

## 4. Compare two futures

Because the same events always produce the same world, a what-if is just another run from the same state:

```elixir
{:ok, noticed, _steps} =
  run.(state, [
    %{type: :tip_left, from: "user", to: "ivy"},
    Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"], at: "09:10"),
    Event.apology_offered("user", "ivy", "I didn't mean to leave you out.", at: "09:12"),
    Event.time_tick("11:00", hours: 2)
  ])
```

```txt
as it happened  Ivy jealousy=10 trust->user=20 confided_in_tae=true
with apology    Ivy jealousy=0 trust->user=28 confided_in_tae=false
```

For comparisons you want to keep, write a scenario with `branches` instead ([scenarios.md](scenarios.md#branches)); the report puts the branches side by side.

## 5. See it as a page

Scenarios are JSON, so any world can become one. Custom event types such as `:tip_left` work in scenarios too when you pass the same pipeline (`Scenario.from_data(data, pipeline: pipeline)`); this version of the morning keeps to built-in events:

```elixir
{:ok, scenario} =
  Aethrion.Scenario.from_data(%{
    "name" => "Cafe morning",
    "world" => state |> State.to_data() |> Map.delete("version"),
    "events" => [
      Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"]) |> Event.to_data(),
      Event.time_tick("11:00", hours: 2) |> Event.to_data()
    ]
  })

{:ok, result} = Aethrion.Scenario.run(scenario)
File.write!("cafe-morning.html", Aethrion.Report.html(result))
```

## 6. Give it a voice

Every line a character says already has deterministic text. To have a model phrase it instead, render the outputs through an adapter. Rendering only changes text; the world is the same either way.

```elixir
{:ok, step} = Runtime.step(morning, Event.message_sent("user", "ivy", "Your latte art made my day.", tone: :warm))

step.outputs
|> Aethrion.Expression.render(adapter: Aethrion.LLM.Anthropic)   # needs ANTHROPIC_API_KEY
|> Enum.filter(&Aethrion.Output.expressive?/1)
|> Enum.each(&IO.puts(&1.text))
```

See [expression.md](expression.md) for adapters, configuration, and how intent interpretation works.

## Where next

- [rules.md](rules.md) - every built-in rule and its numbers
- [scenarios.md](scenarios.md) - scenarios, branches, tuning, and recording sessions
- [api.md](api.md) - the supervised `Aethrion.World` for long-running worlds
