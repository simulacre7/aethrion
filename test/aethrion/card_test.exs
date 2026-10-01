defmodule Aethrion.CardTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Card, Event, Runtime, State, Story}

  # A card written for these tests (not anyone's shared card).
  @data %{
    "name" => "Lumi",
    "description" => "{{char}} runs the lighthouse café and talks to {{user}} every morning.",
    "personality" => "warm, a little shy",
    "scenario" => "A rainy harbor town.",
    "first_mes" => "Oh, {{user}}! You're early today.",
    "mes_example" => "<START>\n{{user}}: Morning.\n{{char}}: Morning! The usual?",
    "alternate_greetings" => ["Hi again."],
    "character_book" => %{
      "entries" => [
        %{
          "keys" => ["lighthouse", "등대"],
          "content" => "The lighthouse has been dark since the storm.",
          "enabled" => true
        },
        %{"keys" => [], "content" => "It always rains on Sundays.", "constant" => true},
        %{"keys" => ["secret"], "content" => "Off.", "enabled" => false},
        %{"keys" => ["folder:abc"], "content" => "A folder."},
        %{
          "keys" => ["harbor"],
          "content" => "@@depth 0\n@@role system\nThe harbor freezes in winter."
        },
        %{
          "keys" => [],
          "constant" => true,
          "content" => "{{#if {{getglobalvar::toggle_x}}}}Print a status window.{{/if}}"
        }
      ]
    },
    "extensions" => %{
      "risuai" => %{"customScripts" => [%{"in" => "a", "out" => "b"}], "triggerscript" => [%{}]}
    }
  }

  defp v2, do: %{"spec" => "chara_card_v2", "spec_version" => "2.0", "data" => @data}
  defp v3, do: %{"spec" => "chara_card_v3", "spec_version" => "3.0", "data" => @data}

  # A minimal PNG carrying text chunks.
  defp png(chunks) do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    texts =
      for {key, json} <- chunks,
          into: <<>>,
          do: chunk.("tEXt", key <> <<0>> <> Base.encode64(Jason.encode!(json)))

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk.("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>) <> texts <> chunk.("IEND", "")
  end

  test "cards in every container read the same" do
    {:ok, zip} = :zip.create(~c"card.charx", [{~c"card.json", Jason.encode!(v3())}], [:memory])
    {:ok, {_name, charx}} = {:ok, zip}

    for bytes <- [
          Jason.encode!(v2()),
          Jason.encode!(v3()),
          Jason.encode!(@data),
          png([{"chara", v2()}]),
          png([{"chara", v2()}, {"ccv3", v3()}]),
          charx
        ] do
      assert {:ok, %{"name" => "Lumi"}} = Card.read(bytes)
    end

    assert {:error, :no_card_in_png} = Card.read(png([]))
    assert {:error, :not_a_card} = Card.read(~s({"hello": 1}))
  end

  test "a card becomes a cast: profile, voice, greeting, lore, and notes on what was left out" do
    {cast, notes} = Card.to_cast(@data)

    assert [
             %{
               "id" => "lumi",
               "name" => "Lumi",
               "profile" => profile,
               "voice" => voice,
               "greeting" => greeting
             }
           ] = cast["characters"]

    assert profile =~ "Lumi runs the lighthouse café and talks to user every morning."
    assert profile =~ "warm, a little shy"
    assert voice =~ "Lumi: Morning! The usual?"
    refute voice =~ "<START>"
    assert greeting == "Oh, user! You're early today."

    assert [%{"keys" => ["lighthouse", "등대"]}, %{"constant" => true}, harbor] =
             cast["story"]["lore"]

    # Decorators, folders, and notes written for RisuAI's own macros are not world text.
    assert harbor == %{"keys" => ["harbor"], "content" => "The harbor freezes in winter."}
    assert "1 lore note written for RisuAI's macros is left out" in notes

    assert "RisuAI regex and trigger scripts are not run" in notes
    assert Enum.any?(notes, &(&1 =~ "alternate greetings"))

    assert {:ok, state} = State.parse(cast)
    assert State.character(state, "lumi").greeting == greeting

    assert {:ok, ^state} =
             state |> State.to_data() |> Jason.encode!() |> Jason.decode!() |> State.parse()
  end

  test "lore comes up when its keys are said, and reaches the model's prompt" do
    {cast, _notes} = Card.to_cast(@data, player: "선장")
    {:ok, state} = State.parse(cast)

    assert Story.lore_for(state, ["What happened to the 등대?"]) == [
             "The lighthouse has been dark since the storm.",
             "It always rains on Sundays."
           ]

    assert Story.lore_for(state, ["Nice weather."]) == ["It always rains on Sundays."]

    {:ok, step} =
      Runtime.step(
        state,
        Event.message_sent("user", "lumi", "Is the lighthouse working?", tone: :neutral)
      )

    [reply] = for %{type: :reply} = o <- step.outputs, do: o
    {_system, context} = Aethrion.Expression.Prompt.render_parts(reply.context)
    assert context =~ "World notes"
    assert context =~ "dark since the storm"
  end

  test "ids come from names, and a non-Latin name gets a stable one" do
    assert Card.id_for("Lumi the Keeper") == "lumi_the_keeper"
    assert Card.id_for("Lázaro") == "lazaro"
    assert "char_" <> _ = Card.id_for("범용상태창 v2")
    assert "char_" <> _ = id = Card.id_for("서윤")
    assert Card.id_for("서윤") == id
  end
end
