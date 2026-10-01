# Cookbook

Patterns for putting Aethrion inside an application. Each recipe uses only the public API; see the [API reference](api.md) for every option.

## A companion app: one world per user

`Aethrion.Worlds` keeps a world per user, keyed by their id (never made an atom), started on first use, stopped when idle, and journaled so it comes back as it was. Give the characters a `voice` so a model can tell them apart.

```elixir
cast = Aethrion.Runtime.demo_state()   # or your own cast, as Aethrion.State

children = [
  {Aethrion.Worlds,
   name: MyApp.Worlds,
   idle_after: :timer.minutes(30),
   world: fn user_id ->
     [
       initial_state: cast,
       journal: "data/worlds/#{user_id}.jsonl",
       journal_compact_every: 500,
       expression: [adapter: Aethrion.LLM.Anthropic, timeout: 10_000]
     ]
   end}
]

Aethrion.Worlds.subscribe(MyApp.Worlds, user_id)
```

When the user types something, let the model *propose* what it means, then dispatch it like any other event:

```elixir
{:ok, state} = Aethrion.Worlds.get_state(MyApp.Worlds, user_id)

{:ok, event, _meta} =
  Aethrion.Intent.interpret(state, text, to: "mina", adapter: Aethrion.LLM.Anthropic)

{:ok, _state, _outputs, _log} = Aethrion.Worlds.dispatch(MyApp.Worlds, user_id, event)
```

Then handle messages in the process that subscribed:

```elixir
# The second element is {manager, key}, so one process can serve many users.
def handle_info({:aethrion, {MyApp.Worlds, _user}, {:expressed, %{type: type} = output}}, socket)
    when type in [:proactive_message, :reply] do
  # output.text is the model's line, or the deterministic fallback
  {:noreply, push_line(socket, output.character_id, output.text)}
end

def handle_info({:aethrion, {MyApp.Worlds, _user}, {:dispatched, step}}, socket) do
  # step.outputs has everything else: mood_changed, bond_changed, ...
  {:noreply, update_panels(socket, step)}
end
```

The model sees the recent conversation (`Aethrion.Conversation`), so a reply follows the thread; what it said is journaled, so after a restart the thread is still there:

```elixir
{:ok, state} = Aethrion.Worlds.get_state(MyApp.Worlds, user_id)
Aethrion.Conversation.recent(state, "mina", "user")   # to show the chat history
```

When the user comes back, show what happened while they were away. Keep the outputs from the subscription since their last visit (store them yourself: a compacted journal starts over from the current state, so it cannot replay what came before):

```elixir
Aethrion.Digest.of(outputs_since_last_visit, state, locale: :ko)
|> Enum.map(& &1.text)
```

`examples/chat_app.exs` runs this shape end to end (two users, a stand-in model that sees the thread, a restart that keeps it). `examples/companion_week.exs` plays ten days of this with the demo cast (five days of mornings with a harsh word and an apology, then five days away) and prints the digest on return, in English and Korean.

To load a save into a running world, `Aethrion.Worlds.put_state(MyApp.Worlds, user_id, state)` (a journaled world starts its journal over from it). The cast only applies when no journal exists yet.

The simulation never waits for the model: `dispatch` returns as soon as the rules have run, and each line arrives when it is rendered (or its fallback, if the model is slow or fails). Rate limits and overload are retried by the adapters.

## A game in another engine: the HTTP API

A Unity, Godot, or web game talks to `mix aethrion.serve` (or `Aethrion.API` in an Elixir app) over JSON. Each save slot is a world key; the game sends what the player did and shows what characters say.

```bash
AETHRION_TOKEN=secret mix aethrion.serve --cast priv/cast.json --data saves --llm anthropic
```

```gdscript
# Godot: the player talks to an NPC
var body = JSON.stringify({"to": "mina", "text": line_edit.text})
http.request("http://127.0.0.1:4848/worlds/slot-1/say",
  ["content-type: application/json", "authorization: Bearer secret"],
  HTTPClient.METHOD_POST, body)

# on request_completed: show each line
for line in JSON.parse_string(body.get_string_from_utf8())["lines"]:
  show_bubble(line["character_id"], line["text"])
```

Witnesses come from the game's own world (`"observed_by": ["yuna"]`), time from its clock (`POST /worlds/slot-1/events` with `{"type": "time_tick", "hours": 6}`), and gifts or apologies are events too (`{"type": "gift_received", "from": "user", "to": "mina", "item": "flower"}`). Lines characters say on their own appear in the response of whatever event caused them, and in `GET /worlds/slot-1/conversation?character=mina&after=e12`.

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

Lines name players by their display name ("Tomas tells Elin what Alex said to Mara"). Each player gets their own digest: `you:` addresses them as "you", and `only_you: true` leaves out messages to, bonds toward, and beliefs and gossip about the other players:

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
