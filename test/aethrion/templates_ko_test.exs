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
    assert Ko.with_particle("flower", :object) == "flower를"
    assert Ko.with_particle("Smith", :subject) == "Smith가"
    assert Ko.with_particle("book", :object) == "book을"
    assert Ko.with_particle("postcard", :object) == "postcard를"
    assert Ko.with_particle("scarf", :object) == "scarf를"
    assert Ko.with_particle("Alex", :subject) == "Alex가"
    assert Ko.with_particle("desk", :object) == "desk를"
    assert Ko.with_particle("cat", :object) == "cat을"
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
             "Yuna는 Haru에게 네가 Mina한테 준 flower 얘기를 전한다.",
             "Yuna한테 들었어. Mina한테 flower 줬다며? 제법인데.",
             "Haru는 한동안 Yuna 곁에 있어 준다. Yuna의 표정이 한결 가벼워진다."
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

  test "gossip about a message says who said it" do
    {state, _outputs} =
      run!(Runtime.demo_state(), [Event.message_sent("user", "yuna", "go away", tone: :hostile)])

    {:ok, step} =
      Runtime.step(state, Event.gossip_shared("yuna", "haru", "memory:yuna:message:e1"))

    [scene] = of_type(step.outputs, :character_interaction)

    assert Ko.render(scene.context) == ~s(Yuna는 Haru에게 네가 자기한테 한 말을 전한다. "go away")
  end

  test "every event in the bundled scenarios is described in Korean" do
    for path <- Aethrion.Scenario.bundled(),
        {:ok, scenario} = Aethrion.Scenario.load(path),
        {:ok, result} = Aethrion.Scenario.run(scenario),
        step <- result.steps ++ Enum.flat_map(result.branches, & &1.steps),
        event <- step.events do
      line = Ko.describe_event(event, &Aethrion.State.name(step.state, &1))
      assert line =~ ~r/\p{Hangul}/u, "no Korean in #{inspect(line)}"
      assert line == :unicode.characters_to_nfc_binary(line)
    end
  end

  test "particles after -ck, a silent e, and digits" do
    assert Aethrion.Expression.Templates.Ko.with_particle("Jack", :topic) == "Jack은"
    assert Aethrion.Expression.Templates.Ko.with_particle("Anne", :subject) == "Anne이"
    assert Aethrion.Expression.Templates.Ko.with_particle("Jerome", :topic) == "Jerome은"
    assert Aethrion.Expression.Templates.Ko.with_particle("Mike", :topic) == "Mike는"
    assert Aethrion.Expression.Templates.Ko.with_particle("3", :topic) == "3은"
    assert Aethrion.Expression.Templates.Ko.with_particle("2", :topic) == "2는"
    assert Aethrion.Expression.Templates.Ko.with_particle("Daphne", :topic) == "Daphne는"
    assert Aethrion.Expression.Templates.Ko.with_particle("anime", :topic) == "anime는"
    assert Aethrion.Expression.Templates.Ko.with_particle("Jane", :topic) == "Jane은"
    assert Aethrion.Expression.Templates.Ko.with_particle("Nicole", :subject) == "Nicole이"
    assert Aethrion.Expression.Templates.Ko.with_particle("candle", :object) == "candle을"
    assert Aethrion.Expression.Templates.Ko.with_particle("ukulele", :object) == "ukulele를"
  end

  test "items take the article they need" do
    assert Aethrion.Expression.Templates.with_article("flower") == "a flower"
    assert Aethrion.Expression.Templates.with_article("apple") == "an apple"
    assert Aethrion.Expression.Templates.with_article("cookies") == "cookies"
    assert Aethrion.Expression.Templates.with_article("glass") == "a glass"
    assert Aethrion.Expression.Templates.with_article("bus") == "a bus"
    assert Aethrion.Expression.Templates.with_article("hour") == "an hour"
    assert Aethrion.Expression.Templates.with_article("unicorn") == "a unicorn"
    assert Aethrion.Expression.Templates.with_article("귤") == "귤"
  end

  test "past tense leaves quoted words alone, wherever a quote appears" do
    request = %Aethrion.Expression.Request{
      kind: :character_interaction,
      reason: :gossip,
      speaker: %{id: "yuna", name: "Yuna", traits: [], mood: :neutral},
      listener: %{id: "haru", name: "Haru"},
      names: %{"user" => "you"},
      memories: [
        %{
          data: %{
            "event" => "gift_received",
            "from" => "user",
            "to" => "yuna",
            "item" => ~s("행운" 부적)
          }
        }
      ]
    }

    assert Aethrion.Expression.Templates.Ko.render(request, tense: :past) ==
             ~s(Yuna는 Haru에게 네가 준 "행운" 부적을 자랑했다.)

    said = %{
      request
      | memories: [
          %{
            data: %{
              "event" => "message_sent",
              "from" => "user",
              "to" => "yuna",
              "tone" => "hostile",
              "text" => "전한다."
            }
          }
        ]
    }

    assert Aethrion.Expression.Templates.Ko.render(said, tense: :past) ==
             ~s(Yuna는 Haru에게 네가 자기한테 한 말을 전했다. "전한다.")
  end
end
