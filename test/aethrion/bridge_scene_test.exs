defmodule Aethrion.BridgeSceneTest do
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Scene
  alias Aethrion.State

  defp cast do
    {:ok, state} =
      State.parse(%{
        "characters" => [
          %{"id" => "haruka", "name" => "Haruka Minase"},
          %{"id" => "char_1", "name" => "무명 (無名)"}
        ],
        "relationships" => [
          %{"from" => "haruka", "to" => "user", "affinity" => 12, "trust" => 3},
          %{"from" => "char_1", "to" => "user", "affinity" => 0, "trust" => 0}
        ]
      })

    state
  end

  describe "take/1" do
    test "takes the scene line out of the reply" do
      reply =
        "The bus stops.\n\n<aethrion-scene>\nHaruka\n- Kenji | captain of the team\n</aethrion-scene>"

      assert Scene.take(reply) ==
               {"The bus stops.",
                [%{name: "Haruka", profile: ""}, %{name: "Kenji", profile: "captain of the team"}]}
    end

    test "a reply cut off inside the line still gives it" do
      assert {"The bus stops.", [%{name: "Haruka", profile: ""}]} =
               Scene.take("The bus stops.\n<aethrion-scene>Haruka")
    end

    test "the player is not someone in the scene" do
      assert {"", [%{name: "Haruka"}]} =
               Scene.take("<aethrion-scene>{{user}}\nThe Player\n나\nHaruka</aethrion-scene>")
    end

    test "an empty line is a scene with no one; no line is no scene" do
      assert Scene.take("Alone.<aethrion-scene></aethrion-scene>") == {"Alone.", []}
      assert Scene.take("Alone.") == {"Alone.", nil}
    end

    test "names are cut to size and cannot break the tag they are kept in" do
      {_text, [entry]} =
        Scene.take(~s(<aethrion-scene>Ha"ru<ka> | a "friend" | really</aethrion-scene>))

      assert entry.name == "Ha ru ka"
      refute entry.profile =~ ~r/["<>;|]/

      long = String.duplicate("가", 300)
      {_text, [entry]} = Scene.take("<aethrion-scene>#{long} | #{long}</aethrion-scene>")
      assert String.length(entry.name) == 40
      assert String.length(entry.profile) == 160

      many = Enum.map_join(1..20, "\n", &"Person #{&1}")
      {_text, entries} = Scene.take("<aethrion-scene>#{many}</aethrion-scene>")
      assert length(entries) == 8
    end
  end

  describe "mark/2 and marked/1" do
    test "the scene travels in the status block's opening tag" do
      scene = [%{name: "Haruka", profile: "a quiet classmate"}, %{name: "Kenji", profile: ""}]
      status = ~s(<aethrion-status id="0a1b2c3d">Haruka · affinity 4</aethrion-status>)
      marked = Scene.mark(status, scene)

      assert marked ==
               ~s(<aethrion-status id="0a1b2c3d" scene="Haruka|a quiet classmate;Kenji">Haruka · affinity 4</aethrion-status>)

      assert Scene.marked("A reply.\n\n" <> marked) == scene
      assert Scene.mark(status, nil) == status
      assert Scene.marked(status) == nil
      # No one there is a scene too.
      assert Scene.marked(Scene.mark(status, [])) == []
    end
  end

  describe "enter/2" do
    test "someone new joins as a stranger; those not named are away" do
      state =
        Scene.enter(cast(), [
          %{name: "Haruka", profile: ""},
          %{name: "Kenji", profile: "captain of the team"}
        ])

      assert [%{name: "Haruka Minase"}, %{name: "Kenji", profile: "captain of the team"}, _] =
               state |> State.sorted_characters() |> Enum.sort_by(& &1.name)

      kenji = Enum.find(State.sorted_characters(state), &(&1.name == "Kenji"))
      assert %{affinity: 0, trust: 0} = State.get_relationship(state, kenji.id, "user")
      # Known under a fuller name, and still who she was.
      assert %{affinity: 12, trust: 3} = State.get_relationship(state, "haruka", "user")
      assert State.stat(state, "haruka", "away") == 0
      assert State.stat(state, "char_1", "away") == 1

      # Back in the next scene, under the short form of the name.
      back = Scene.enter(state, [%{name: "무명", profile: ""}])
      assert State.stat(back, "char_1", "away") == 0
      assert State.stat(back, "haruka", "away") == 1
      assert State.stat(back, kenji.id, "away") == 1
      assert length(State.sorted_characters(back)) == 3
    end

    test "the cast stops growing at sixteen" do
      entries = for n <- 1..8, do: %{name: "Person #{n}", profile: ""}
      more = for n <- 9..16, do: %{name: "Person #{n}", profile: ""}
      last = for n <- 17..24, do: %{name: "Person #{n}", profile: ""}

      state = cast() |> Scene.enter(entries) |> Scene.enter(more) |> Scene.enter(last)
      assert length(State.sorted_characters(state)) == 16
    end

    test "two people whose names give the same id are both kept" do
      state =
        Scene.enter(cast(), [%{name: "Ken-ji", profile: ""}, %{name: "Ken ji", profile: ""}])

      names = state |> State.sorted_characters() |> Enum.map(& &1.name)
      assert "Ken-ji" in names and "Ken ji" in names
    end
  end

  describe "filter/1" do
    defp streamed(pieces) do
      {on_delta, flush} = Scene.filter(&send(self(), {:out, &1}))
      Enum.each(pieces, on_delta)
      flush.()

      Stream.repeatedly(fn ->
        receive do
          {:out, text} -> text
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.join()
    end

    test "holds the scene line back, however the pieces fall" do
      text = "The bus stops. <b>Now</b>\n<aethrion-scene>Haruka | a classmate</aethrion-scene>"

      for size <- [1, 3, 7, 200] do
        pieces = for [piece] <- Regex.scan(~r/.{1,#{size}}/s, text), do: piece
        assert streamed(pieces) == "The bus stops. <b>Now</b>\n"
      end
    end

    test "what only looked like its beginning is passed on" do
      assert streamed(["He said <aeth", "er> and left <aethrion-sc"]) ==
               "He said <aether> and left <aethrion-sc"
    end
  end
end
