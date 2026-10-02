# mix run examples/den.exs
#
# A wolf den fought with the d20 rules of the D&D 5th edition SRD
# (priv/casts/den.json: the dire wolf and wolves are SRD 5.1 stat blocks,
# CC-BY-4.0, see priv/casts/SRD-NOTICE.md). Every line is typed the way a
# player types in a chat; Aethrion.Chat reads what it does. The dice are
# rolled from the fight itself, so each run is the same, and how the player
# treats the cleric and the rogue decides who stands beside them at the end.

alias Aethrion.{Chat, Combat, Intent, Runtime, State}

{:ok, den} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> State.parse()

play = fn lines ->
  # The route's lines, then its last line again until the fight is settled.
  turns = lines ++ List.duplicate(List.last(lines), 30)

  Enum.reduce_while(turns, {den, []}, fn text, {state, told} ->
    {state, said} =
      Enum.reduce(Chat.read_all(state, "user", "sera", text), {state, ["> " <> text]}, fn
        {:talk, to, words}, {state, said} ->
          {:ok, event, _meta} = Intent.interpret(state, words, to: to)
          {:ok, step} = Runtime.step(state, event)
          {step.state, said}

        :talk, {state, said} ->
          # Talk to whoever the line starts by calling, else the cleric.
          to = if String.starts_with?(text, "도윤"), do: "doyun", else: "sera"
          {:ok, event, _meta} = Intent.interpret(state, text, to: to)
          {:ok, step} = Runtime.step(state, event)
          {step.state, said}

        {_as, event}, {state, said} ->
          case Runtime.step(state, event) do
            {:ok, step} ->
              lines =
                for %{type: :combat} = o <- step.outputs, do: "  " <> Combat.describe(o, step.state, :ko)

              {step.state, said ++ lines}

            {:error, error} ->
              {state, said ++ ["  (" <> error.message <> ")"]}
          end
      end)

    told = told ++ said

    case Aethrion.Rules.Ending.reached(state) do
      nil -> {:cont, {state, told}}
      ending -> {:halt, {state, told, ending}}
    end
  end)
end

routes = %{
  "1 together" => [
    "세라, 도윤, 고마워. 너희가 있어서 든든해.",
    "다이어 울프에게 롱소드를 휘두른다",
    "도윤, 엄호 부탁해! 회색 늑대를 벤다",
    "검은 늑대를 내리친다",
    "세라, 나 좀 치료해줘",
    "다이어 울프의 목을 노려 찌른다"
  ],
  "2 alone" => [
    "세라, 방해만 되니까 빠져. 짐짝이야.",
    "도윤, 너도 쓸모없어. 저리 가.",
    "다이어 울프를 벤다"
  ],
  "3 retreat" => [
    "다이어 울프를 벤다",
    "도망친다! 다들 뛰어!"
  ]
}

for {name, lines} <- Enum.sort(routes) do
  IO.puts("== " <> name)

  case play.(lines) do
    {_state, told, ending} ->
      Enum.each(Enum.take(told, 14), &IO.puts/1)
      IO.puts("  ...")
      IO.puts("  ★ #{ending.title}: #{ending.description}\n")

    {_state, told} ->
      Enum.each(Enum.take(told, 14), &IO.puts/1)
      IO.puts("  (no ending yet)\n")
  end
end
