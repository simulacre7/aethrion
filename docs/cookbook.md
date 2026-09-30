# Cookbook

Patterns for putting Aethrion inside an application. Each recipe uses only the public API; see the [API reference](api.md) for every option.

## A companion app: one world per user

Each user gets their own `Aethrion.World`, journaled so it survives restarts and compacted so it starts quickly. The app subscribes to hear what characters say.

```elixir
children = [
  {Aethrion.World,
   name: :"world_#{user_id}",
   initial_state: MyApp.Worlds.starting_state(),
   journal: "data/worlds/#{user_id}.jsonl",
   journal_compact_every: 500,
   scheduler: [interval_ms: 60_000, tick_hours: 1],
   expression: [adapter: Aethrion.LLM.Anthropic, timeout: 10_000]}
]

Aethrion.World.subscribe(:"world_#{user_id}")
```

When the user types something, let the model *propose* what it means, then dispatch it like any other event:

```elixir
state = Aethrion.World.get_state(world)

{:ok, event, _meta} =
  Aethrion.Intent.interpret(state, text, to: "mina", adapter: Aethrion.LLM.Anthropic)

{:ok, _state, _outputs, _log} = Aethrion.World.dispatch(world, event)
```

Then handle messages in the process that subscribed:

```elixir
# The second element is the world's name, so one process can serve many worlds.
# Subscriptions survive a runtime restart.
def handle_info({:aethrion, _world, {:expressed, %{type: type} = output}}, socket)
    when type in [:proactive_message, :reply] do
  # output.text is the model's line, or the deterministic fallback
  {:noreply, push_line(socket, output.character_id, output.text)}
end

def handle_info({:aethrion, _world, {:dispatched, step}}, socket) do
  # step.outputs has everything else: mood_changed, bond_changed, ...
  {:noreply, update_panels(socket, step)}
end
```

When the user comes back, show what happened while they were away. Keep the outputs from the subscription since their last visit (store them yourself: a compacted journal starts over from the current state, so it cannot replay what came before):

```elixir
Aethrion.Digest.of(outputs_since_last_visit, Aethrion.World.get_state(world), locale: :ko)
|> Enum.map(& &1.text)
```

`examples/companion_week.exs` plays ten days of this with the demo cast (five days of mornings with a harsh word and an apology, then five days away) and prints the digest on return, in English and Korean.

To load a save into a running world, `Aethrion.World.put_state(world, state)` (a journaled world starts its journal over from it). A world's `:initial_state` only applies when no journal or snapshot exists yet. World names are atoms, so start worlds for active users and stop idle ones (`DynamicSupervisor.terminate_child(sup, Aethrion.World.whereis(name))`) rather than keeping one per user ever seen.

The simulation never waits for the model: `dispatch` returns as soon as the rules have run, and each line arrives when it is rendered (or its fallback, if the model is slow or fails).

## Game NPCs: witnesses and bonds

Your game knows who is standing nearby; pass them as witnesses. Characters who care about the target judge the speaker, may speak up, and remember it.

```elixir
nearby = MyGame.characters_within(player, 8.0)

event =
  Aethrion.Event.message_sent(player.id, "mina", line, tone: tone, observed_by: nearby)
```

Drive time from your game clock (`Aethrion.Event.time_tick("day 3 evening", hours: 6)`), and use bonds for UI instead of raw numbers. After any step:

```elixir
for %{type: :bond_changed, from: npc, to: player, after: bond} <- step.outputs do
  MyGame.Notifications.push("#{npc} now feels #{bond} toward #{player}")
end

# The current bond, any time:
Aethrion.Rules.Bond.derive(Aethrion.State.get_relationship(state, "mina", player.id), state)
```

## Several people in one world

Any actor id that is not a character is a person. Give each player their own id, a display name, and relationships; characters address proactive messages to the person they are about (jealousy to the gift's giver, curiosity to the person the news is about, protectiveness to whoever was hostile).

```elixir
state = Aethrion.State.new(characters: cast, relationships: rels,
                           people: %{"player:alex" => "Alex", "player:sam" => "Sam"})

Aethrion.Event.gift_received("player:alex", "mina", "ring", observed_by: ["yuna"])
```

Lines name players by their display name ("Tomas tells Elin what Alex said to Mara"). Each player gets their own digest: `you:` addresses them as "you", and `only_you: true` leaves out messages to, bonds toward, and beliefs about the other players:

```elixir
Aethrion.Digest.of(outputs, state, you: "player:sam", only_you: true)
```

See `priv/scenarios/11_two_regulars.json`.

## A rule of your own

Rules are small modules; numbers go in `params` so worlds can tune them.

```elixir
defmodule MyGame.Rules.FavoriteGift do
  use Aethrion.Rule,
    id: :favorite_gift,
    description: "A favorite item delights the receiver.",
    params: [joy_bonus: 15]

  alias Aethrion.Transition

  @impl true
  def apply(%Transition{event: event} = transition) do
    if event.item in MyGame.favorites(event.to) do
      transition
      |> Transition.adjust_character(event.to, :joy, Transition.param(transition, :joy_bonus))
      |> Transition.note("#{Transition.name(transition, event.to)} loves #{event.item}")
    else
      transition
    end
  end
end

pipeline = Aethrion.Pipeline.append(Aethrion.Pipeline.default(), :gift_received, MyGame.Rules.FavoriteGift)
```

Pass the same `pipeline:` everywhere the world is run, loaded, replayed, or compacted.

## Pin behavior down with scenarios

Write the behavior you want as a scenario with expectations; it runs as a test.

```json
{"name": "Favorite gift",
 "events": [{"type": "gift_received", "from": "user", "to": "mina", "item": "tea"}],
 "expect": [{"character": "mina", "field": "joy", "at_least": 30},
            {"relationship": ["mina", "user"], "field": "bond", "equals": "friendly"}]}
```

```elixir
{:ok, scenario} = Aethrion.Scenario.load("test/scenarios/favorite_gift.json", pipeline: pipeline)
{:ok, result} = Aethrion.Scenario.run(scenario, pipeline: pipeline)
assert Aethrion.Scenario.passed?(result)
```

Playing in `mix demo.interactive` and typing `record path.json` turns a session into such a file.

## Explain a surprise

When a character does something unexpected, ask why:

```elixir
{:ok, _state, steps} = Aethrion.run(state, events)

steps
|> Aethrion.Explain.relationship("haru", "user", :trust)
|> Aethrion.Explain.describe()
```

In a running world, subscribe and keep the steps you care about, or journal the world and replay it: `Aethrion.Journal.replay/2` returns every step.
