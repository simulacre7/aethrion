defmodule Aethrion.TemplatesKoTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Expression, Runtime}
  alias Aethrion.Expression.Templates.Ko

  test "particles follow the final sound of Hangul and Latin names" do
    assert Ko.with_particle("미나", :subject) == "미나가"
    assert Ko.with_particle("하늘", :subject) == "하늘이"
    assert Ko.with_particle("솔", :topic) == "솔은"
    assert Ko.with_particle("Mina", :and) == "Mina랑"
    assert Ko.with_particle("Sol", :and) == "Sol이랑"
    assert Ko.with_particle("Haru", :object) == "Haru를"
    assert Ko.with_particle("Ivy", :topic) == "Ivy는"
    assert Ko.with_particle("Haru", :with) == "Haru와"
    assert Ko.with_particle("Sol", :with) == "Sol과"
    assert Ko.with_particle(:unicode.characters_to_nfd_binary("민아"), :subject) =~ "가"
    assert Ko.with_particle("하늘❤️", :subject) == "하늘❤️이"
    assert Ko.with_particle("Zoe\u0308", :subject) == "Zoe\u0308가"
    assert Ko.with_particle("", :topic) == "는"
  end

  test "the fake adapter renders every expressive output in Korean without touching the simulation" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {_state, outputs} = dispatch!(state, Event.time_tick("t", hours: 2))

    rendered =
      Expression.render(outputs, adapter: Aethrion.LLM.FakeAdapter, adapter_opts: [locale: :ko])

    texts = for output <- rendered, Aethrion.Output.expressive?(output), do: output.text

    assert texts == [
             "아까 Mina랑 있을 때 즐거워 보이더라. 혹시 나는 잊은 거 아니지?",
             "Yuna는 Haru에게 네가 Mina한테 준 flower 이야기를 털어놓는다.",
             "Yuna한테 들었어. Mina한테 flower 줬다며? 제법인데.",
             "Haru는 한동안 Yuna 곁에 있어 준다. Yuna가 조금 가벼워진 얼굴이다."
           ]

    # Only text changes; every other field, and the state, is untouched.
    assert Enum.map(rendered, &Map.drop(&1, [:text, :expression])) ==
             Enum.map(outputs, &Map.delete(&1, :text))
  end

  test "replies and history-aware lines have Korean versions" do
    {_state, outputs} =
      dispatch!(
        Runtime.demo_state(),
        Event.message_sent("user", "mina", "go away", tone: :hostile)
      )

    assert [%{text: "왜 그런 말을 해?"}] =
             outputs
             |> of_type(:reply)
             |> Expression.render(adapter: Aethrion.LLM.FakeAdapter, adapter_opts: [locale: :ko])
  end

  test "every line the bundled scenarios produce renders in Korean" do
    requests =
      for path <- Aethrion.Scenario.bundled(),
          {:ok, scenario} = Aethrion.Scenario.load(path),
          {:ok, result} = Aethrion.Scenario.run(scenario),
          output <- result.outputs ++ Enum.flat_map(result.branches, & &1.outputs),
          match?(%{context: %Aethrion.Expression.Request{}}, output),
          do: output.context

    assert length(requests) > 50

    for request <- requests do
      line = Ko.render(request)
      assert line =~ ~r/\p{Hangul}/u, "no Korean in #{inspect(line)} for #{inspect(request.kind)}"
      refute line =~ ~r/[{}]|nil/, "unfilled template: #{inspect(line)}"
      assert line == :unicode.characters_to_nfc_binary(line)
    end

    # The scenarios reach most template branches, in both languages.
    kinds = requests |> Enum.map(&{&1.kind, &1.reason}) |> Enum.uniq()
    assert length(kinds) >= 7
  end
end
