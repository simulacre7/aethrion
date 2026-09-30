# mix run examples/tutorial_cafe.exs
#
# The code from docs/tutorial.md: a small cafe with its own cast, a custom rule
# for a regular customer, a what-if comparison, and an HTML report.

alias Aethrion.{
  Character,
  CharacterState,
  Event,
  Pipeline,
  Relationship,
  Runtime,
  State
}

# 1. A world: three people who work at a cafe.
state =
  State.new(
    characters: [
      %Character{
        id: "sol",
        name: "Sol",
        profile: "Owner. Remembers every regular's order.",
        traits: [:calm]
      },
      %Character{
        id: "ivy",
        name: "Ivy",
        profile: "Barista. Loves attention from the regulars.",
        traits: [:sensitive]
      },
      %Character{
        id: "tae",
        name: "Tae",
        profile: "Weekend baker. Hears all the gossip.",
        traits: [:talkative],
        state: %CharacterState{loneliness: 20}
      }
    ],
    relationships: [
      %Relationship{from: "ivy", to: "user", affinity: 35, trust: 20},
      %Relationship{from: "sol", to: "user", affinity: 25, trust: 30},
      %Relationship{from: "tae", to: "ivy", affinity: 30, trust: 45},
      %Relationship{from: "ivy", to: "tae", affinity: 30, trust: 40}
    ]
  )

# 2. A custom rule: whoever the user tips feels appreciated; Sol, who runs the
#    place, trusts regulars who tip.
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
    |> Transition.adjust_relationship(
      "sol",
      event.from,
      :trust,
      Transition.param(transition, :owner_trust)
    )
    |> Transition.note("#{Transition.name(transition, event.to)} got a tip from #{event.from}")
  end
end

pipeline = Pipeline.append(Pipeline.default(), :tip_left, Cafe.Rules.Tip)
run = fn state, events -> Runtime.run(state, events, pipeline: pipeline) end

# 3. A morning at the cafe.
{:ok, morning, steps} =
  run.(state, [
    %{type: :tip_left, from: "user", to: "ivy"},
    Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"], at: "09:10"),
    Event.time_tick("11:00", hours: 2)
  ])

IO.puts("== the morning")
steps |> Enum.flat_map(& &1.log) |> Enum.each(&IO.puts/1)

# 4. What if the user had noticed Ivy and apologized before leaving?
{:ok, noticed, noticed_steps} =
  run.(state, [
    %{type: :tip_left, from: "user", to: "ivy"},
    Event.gift_received("user", "sol", "pastry box", observed_by: ["ivy"], at: "09:10"),
    Event.apology_offered("user", "ivy", "I didn't mean to leave you out.", at: "09:12"),
    Event.time_tick("11:00", hours: 2)
  ])

IO.puts("\n== what if the user had apologized to Ivy?")

for {label, world, steps} <- [
      {"as it happened", morning, steps},
      {"with apology", noticed, noticed_steps}
    ] do
  ivy = world.characters["ivy"].state

  confided? =
    Enum.any?(steps, fn step -> Enum.any?(step.events, &(&1.type == :gossip_shared)) end)

  IO.puts(
    "#{String.pad_trailing(label, 15)} Ivy jealousy=#{ivy.jealousy} trust->user=#{Aethrion.State.get_relationship(world, "ivy", "user").trust} confided_in_tae=#{confided?}"
  )
end

# 5. The same morning as a scenario report. Custom event types are not part of
#    the JSON format, so this uses only built-in events.
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
path = Path.join(System.tmp_dir!(), "cafe-morning.html")
File.write!(path, Aethrion.Report.html(result))
IO.puts("\nreport: #{path}")
