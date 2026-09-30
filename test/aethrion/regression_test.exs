defmodule Aethrion.RegressionTest do
  @moduledoc """
  Regression tests for defects found in the v0.2 review.
  """

  use ExUnit.Case, async: true

  import Aethrion.TestHelpers
  import ExUnit.CaptureLog

  alias Aethrion.{Event, Expression, Runtime, RuntimeServer, Scenario, State}
  alias Aethrion.Persistence.JsonFile

  describe "hand-built events with omitted optional fields" do
    test "are normalized instead of crashing a rule" do
      state = Runtime.demo_state()

      assert {:ok, _state, _outputs, _log} =
               Runtime.dispatch(state, %{type: :time_tick, hours: 1})

      assert {:ok, next, _outputs, _log} =
               Runtime.dispatch(state, %{
                 type: :gift_received,
                 from: "user",
                 to: "mina",
                 item: "x"
               })

      assert [%{created_at: "unspecified"}] = next.memories

      assert {:ok, _state, _outputs, _log} =
               Runtime.dispatch(state, %{
                 type: :message_sent,
                 from: "user",
                 to: "mina",
                 text: "hi"
               })
    end

    test "a crashing custom rule is rejected without killing the runtime server" do
      defmodule Boom do
        use Aethrion.Rule, id: :boom, description: "Always raises."
        @impl true
        def apply(_transition), do: raise("boom")
      end

      pipeline = Aethrion.Pipeline.append(Aethrion.Pipeline.default(), :time_tick, Boom)
      server = start_supervised!({RuntimeServer, pipeline: pipeline})
      before = RuntimeServer.get_state(server)

      capture_log(fn ->
        assert {:error, %{code: :rule_failed, message: message}} =
                 RuntimeServer.dispatch(server, Event.time_tick("t", hours: 1))

        assert message =~ "boom"
      end)

      assert RuntimeServer.get_state(server) == before
      assert {:ok, _state, _outputs, _log} = RuntimeServer.dispatch(server, flower_for_mina())
    end
  end

  describe "untrusted json" do
    test "unknown traits stay strings and never create atoms" do
      name = "trait-#{System.unique_integer([:positive])}-never-an-atom"

      {:ok, state} =
        State.parse(%{
          "characters" => [%{"id" => "a", "name" => "A", "traits" => [name, "talkative"]}]
        })

      assert State.character(state, "a").traits == [name, :talkative]
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "malformed state data is reported with a path" do
      cases = [
        {[], []},
        {%{"characters" => [%{"id" => "a"}]}, ["characters", 0, "name"]},
        {%{"characters" => [%{"id" => "a", "name" => "A", "state" => %{"loneliness" => "x"}}]},
         ["characters", 0, "state", "loneliness"]},
        {%{"characters" => [%{"id" => "a", "name" => "A", "traits" => "x"}]},
         ["characters", 0, "traits"]},
        {%{"relationships" => [%{"from" => "a", "to" => "b", "trust" => 500}]},
         ["relationships", 0, "trust"]},
        {%{"memories" => [%{"id" => "m"}]}, ["memories", 0, "character_id"]}
      ]

      for {data, path} <- cases do
        assert {:error, %{code: :invalid_state, details: %{path: ^path}}} = State.parse(data)
      end
    end

    test "a corrupted snapshot stops the server instead of being overwritten" do
      path = Path.join(System.tmp_dir!(), "aethrion-corrupt-#{System.unique_integer()}.json")
      File.write!(path, ~s({"characters": [{"id": "a"}]}))
      on_exit(fn -> File.rm(path) end)

      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:error, %{code: :invalid_snapshot, details: %{error: %{code: :invalid_state}}}} =
                 RuntimeServer.start_link(persistence: {JsonFile, path: path})
      end)

      assert File.read!(path) == ~s({"characters": [{"id": "a"}]})
    end

    test "odd scenario values produce errors or readable descriptions, not crashes" do
      assert {:error, %{code: :invalid_scenario, details: %{path: ["name"], value: 1.5}}} =
               Scenario.from_data(%{"name" => 1.5})

      assert {:error,
              %{code: :invalid_state, details: %{path: ["world", "characters", 0, "traits"]}}} =
               Scenario.from_data(%{
                 "world" => %{"characters" => [%{"id" => "a", "name" => "A", "traits" => "x"}]}
               })

      {:ok, scenario} =
        Scenario.from_data(%{
          "expect" => [
            %{"character" => "mina", "field" => "mood", "equals" => %{"a" => 1}},
            %{"memory" => %{"data" => %{"a" => 1}}}
          ]
        })

      {:ok, result} = Scenario.run(scenario)

      assert [~s(mina.mood == %{"a" => 1}), ~s(memory data=%{"a" => 1} count >= 1)] =
               Enum.map(result.checks, & &1.description)

      assert Aethrion.Report.html(result) =~ "&quot;a&quot;"
    end
  end

  test "a jealous line only blames the user for the user's own gifts" do
    state =
      Runtime.demo_state()
      |> State.update_relationship("yuna", "haru", &%{&1 | affinity: 40})

    {_state, outputs} =
      run!(state, [
        Event.gift_received("haru", "mina", "ring", observed_by: ["yuna"]),
        Event.time_tick("t", hours: 1)
      ])

    assert [%{reason: :jealous, text: text}] = proactive(outputs, "yuna")
    refute text =~ "Mina"
  end

  test "blocked or inactive characters cannot comfort or gossip" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    state = State.update_character_state(state, "haru", &%{&1 | blocked?: true})

    assert {:error, %{code: :unavailable_character, details: %{field: :from}}} =
             Runtime.dispatch(state, Event.comfort_offered("haru", "yuna"))

    assert {:error, %{code: :unavailable_character, details: %{field: :to}}} =
             Runtime.dispatch(
               state,
               Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1")
             )

    assert {:ok, _state, _outputs, _log} =
             Runtime.dispatch(state, Event.comfort_offered("user", "yuna"))
  end

  test "characters cannot give themselves gifts" do
    assert {:error, %{code: :invalid_event, details: %{field: :from}}} =
             Runtime.dispatch(Runtime.demo_state(), Event.gift_received("mina", "mina", "x"))
  end

  test "whitespace-only renderings fall back" do
    defmodule Blank do
      @behaviour Aethrion.LLM.Adapter
      @impl true
      def render(_request, _opts), do: {:ok, "   \n"}
    end

    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {_state, outputs} = dispatch!(state, Event.time_tick("t", hours: 2))

    for output <- Expression.render(outputs, adapter: Blank),
        Aethrion.Output.expressive?(output) do
      assert output.text != ""
      assert %{status: :fallback, reason: :empty_response} = output.expression
    end
  end

  describe "second review" do
    alias Aethrion.{Memory, Pipeline, Tuning}
    alias Aethrion.Rules.{Consolidation, MemoryDecay}

    test "tuned importance cannot push memories outside 0..100" do
      state =
        Runtime.demo_state()
        |> Tuning.put(:gift, :importance, 250)
        |> Tuning.put(:consolidation, :per_occurrence, -50)

      {state, _outputs} =
        run!(state, [
          Event.gift_received("user", "mina", "a"),
          Event.gift_received("user", "mina", "b"),
          Event.time_tick("t", hours: 2000)
        ])

      assert Enum.all?(state.memories, &(&1.importance in 0..100 and &1.strength in 0..100))

      assert {:ok, _state} =
               state |> State.to_data() |> Jason.encode!() |> Jason.decode!() |> State.parse()
    end

    test "tuning for custom rules survives persistence and scenarios with the same pipeline" do
      defmodule Custom do
        use Aethrion.Rule, id: :custom_tuned, description: "Test rule.", params: [k: 1]
        @impl true
        def apply(transition), do: transition
      end

      pipeline = Pipeline.append(Pipeline.default(), :time_tick, Custom)
      state = Tuning.put(Runtime.demo_state(), Custom, :k, 5)
      data = state |> State.to_data() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, %{tuning: %{custom_tuned: %{k: 5}}}} = State.parse(data, pipeline: pipeline)
      assert {:ok, %{tuning: tuning}} = State.parse(data)
      refute Map.has_key?(tuning, :custom_tuned)

      assert {:ok, scenario} =
               Scenario.from_data(%{"tuning" => %{"custom_tuned" => %{"k" => 7}}},
                 pipeline: pipeline
               )

      assert scenario.state.tuning.custom_tuned == %{k: 7}

      path = Path.join(System.tmp_dir!(), "aethrion-custom-#{System.unique_integer()}.json")
      on_exit(fn -> File.rm(path) end)
      :ok = JsonFile.save(state, path: path)

      server =
        start_supervised!(
          {RuntimeServer, pipeline: pipeline, persistence: {JsonFile, path: path}}
        )

      assert RuntimeServer.get_state(server).tuning.custom_tuned == %{k: 5}
    end

    test "impressions do not depend on how time was split into ticks" do
      events = [
        Event.message_sent("user", "mina", "a", tone: :warm),
        Event.time_tick("t", hours: 48),
        Event.message_sent("user", "mina", "b", tone: :warm)
      ]

      {base, _outputs} = run!(Runtime.demo_state(), events)
      {one_tick, _outputs} = dispatch!(base, Event.time_tick("t", hours: 152))
      {hourly, _outputs} = run!(base, for(_ <- 1..152, do: Event.time_tick("t", hours: 1)))

      impression = fn state ->
        State.memory(state, "memory:mina:impression:warm:user")
      end

      assert impression.(one_tick).created_tick == impression.(hourly).created_tick
      assert impression.(one_tick).strength == impression.(hourly).strength
      refute Memory.faded?(impression.(one_tick))
    end

    test "impressions decay more slowly, and faded impressions stop counting" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "mina", "a", tone: :warm),
          Event.message_sent("user", "mina", "b", tone: :warm),
          Event.time_tick("t", hours: 200)
        ])

      assert Consolidation.impression_count(state, "mina", "warm", "user") == 2

      # An ordinary importance-60 memory fades after 96h; the impression lasts 4x as long.
      {state, _outputs} = dispatch!(state, Event.time_tick("t", hours: 200))
      assert Consolidation.impression_count(state, "mina", "warm", "user") == 2

      {state, _outputs} = dispatch!(state, Event.time_tick("t", hours: 400))
      assert Consolidation.impression_count(state, "mina", "warm", "user") == 0
    end

    test "memory decay traces oldest first, each fade note right after its change" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "mina", "first", tone: :cold),
          Event.message_sent("user", "haru", "second", tone: :cold)
        ])

      {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 100))

      decay = Enum.filter(step.trace, &(&1.rule == :memory_decay))

      assert [
               %{kind: :memory, target: "memory:mina:message:e1"},
               %{kind: :note, subject: "mina"},
               %{kind: :memory, target: "memory:haru:message:e2"},
               %{kind: :note, subject: "haru"}
             ] = decay
    end

    test "fade_tick inverts strength_at" do
      for importance <- [0, 19, 20, 21, 45, 60, 99], unit <- [1, 24, 96] do
        memory =
          Memory.new(
            id: "m",
            character_id: "a",
            content: "",
            importance: importance,
            created_at: "t",
            created_tick: 10
          )

        tick = MemoryDecay.fade_tick(memory, unit)

        assert MemoryDecay.strength_at(memory, tick, unit) < Memory.faded_threshold()

        if tick > 10 do
          assert MemoryDecay.strength_at(memory, tick - 1, unit) >= Memory.faded_threshold()
        end
      end

      assert MemoryDecay.fade_tick(
               Memory.new(
                 id: "m",
                 character_id: "a",
                 content: "",
                 importance: 100,
                 created_at: "t"
               )
             ) == nil
    end

    test "non-string branch names are rejected" do
      assert {:error, %{code: :invalid_scenario, details: %{path: ["branches", 0, "name"]}}} =
               Scenario.from_data(%{"branches" => [%{"name" => %{"x" => 1}}]})
    end

    test "loading a world in the interactive demo clears the previous world's history" do
      path =
        Path.join(System.tmp_dir!(), "aethrion-load-#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)
      :ok = JsonFile.save(Runtime.demo_state(), path: path)

      output =
        ExUnit.CaptureIO.capture_io(
          "gift user mina flower\nload #{path}\ntimeline\nwhy mina\nquit\n",
          fn ->
            Mix.Tasks.Demo.Interactive.run(["--no-status"])
          end
        )
        |> String.replace(~r/\e\[[0-9;]*m/, "")

      [_before, after_load] = String.split(output, "loaded #{path}")
      assert after_load =~ "no events yet"
      assert after_load =~ "nothing yet"
    end
  end

  describe "third review" do
    alias Aethrion.{Journal, Tuning}

    setup do
      path =
        Path.join(System.tmp_dir!(), "aethrion-r3-#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "time labels must be strings" do
      assert {:error, %{code: :invalid_event, details: %{field: :at}}} =
               Runtime.dispatch(Runtime.demo_state(), %{
                 type: :gift_received,
                 from: "user",
                 to: "mina",
                 item: "x",
                 at: {2026, 1, 1}
               })

      assert {:error, %{code: :invalid_event, details: %{field: :now}}} =
               Runtime.dispatch(Runtime.demo_state(), %{
                 type: :time_tick,
                 hours: 1,
                 now: ~U[2026-01-01 00:00:00Z]
               })
    end

    test "events that would not replay unchanged are rejected before the state changes", %{
      path: path
    } do
      defmodule Stamp do
        use Aethrion.Rule, id: :stamp_test, description: "Test rule."
        @impl true
        def apply(transition), do: transition
      end

      pipeline = Aethrion.Pipeline.append(Aethrion.Pipeline.default(), :stamp_test, Stamp)
      server = start_supervised!({RuntimeServer, journal: path, pipeline: pipeline})
      before = RuntimeServer.get_state(server)

      # An atom value comes back from JSON as a string.
      assert {:error,
              %{code: :invalid_event, message: "event cannot be journaled faithfully" <> _}} =
               RuntimeServer.dispatch(server, %{type: :stamp_test, mood: :sparkly})

      assert RuntimeServer.get_state(server) == before

      assert {:ok, _state, _outputs, _log} =
               RuntimeServer.dispatch(server, %{type: :stamp_test, note: "ok"})

      assert {:ok, _state, [_step]} = Journal.replay(path, pipeline: pipeline)
    end

    test "a failed journal append rejects the event and keeps the journal replayable", %{
      path: path
    } do
      server = start_supervised!({RuntimeServer, journal: path})
      {:ok, state, _outputs, _log} = RuntimeServer.dispatch(server, flower_for_mina())

      File.chmod!(path, 0o444)

      capture_log(fn ->
        assert {:error, %{code: :journal_failed}} =
                 RuntimeServer.dispatch(server, Event.time_tick("t", hours: 1))
      end)

      File.chmod!(path, 0o644)

      assert RuntimeServer.get_state(server) == state
      assert {:ok, ^state, _steps} = Journal.replay(path)
    end

    test "journal headers are written atomically and validated", %{path: path} do
      :ok = Journal.create(path, Runtime.demo_state())
      assert {:error, %{code: :already_exists}} = Journal.create(path, Runtime.demo_state())
      refute File.exists?(path <> ".tmp")

      File.write!(path, ~s({"aethrion_journal": 1}\n))

      assert {:error, %{code: :invalid_journal, details: %{line: 1, reason: :missing_state}}} =
               Journal.read(path)
    end

    test "impressions form the same way however time is split, even across forgetting" do
      warm = fn text -> Event.message_sent("user", "mina", text, tone: :warm) end
      base = [warm.("a"), warm.("b"), warm.("c")]
      impression = &State.memory(&1, "memory:mina:impression:warm:user")

      {one, _outputs} = run!(Runtime.demo_state(), base ++ [Event.time_tick("t", hours: 1000)])

      {ten, _outputs} =
        run!(Runtime.demo_state(), base ++ for(_ <- 1..10, do: Event.time_tick("t", hours: 100)))

      assert impression.(one).data["count"] == 3
      assert impression.(ten).data["count"] == 3
    end

    test "sparse patterns still consolidate" do
      warm = fn text -> Event.message_sent("user", "mina", text, tone: :warm) end
      days = for _ <- 1..35, do: Event.time_tick("t", hours: 24)

      {state, _outputs} =
        run!(
          Runtime.demo_state(),
          [warm.("a")] ++ days ++ [warm.("b"), Event.time_tick("t", hours: 200)]
        )

      assert State.memory(state, "memory:mina:impression:warm:user").data["count"] == 2
    end

    test "curiosity can fire on any event, not only ticks and gossip" do
      state =
        Runtime.demo_state()
        |> State.update_relationship("yuna", "user", &%{&1 | affinity: 25})
        |> State.update_relationship("mina", "yuna", &%{&1 | trust: 40})

      {state, _outputs} =
        run!(state, [
          Event.gift_received("user", "haru", "tea", observed_by: ["mina"]),
          Event.gossip_shared("mina", "yuna", "memory:mina:observed:e1")
        ])

      {_state, outputs} =
        run!(state, [
          Event.message_sent("user", "yuna", "hi", tone: :warm),
          Event.message_sent("user", "yuna", "hello again", tone: :warm)
        ])

      assert [%{reason: :curious}] = proactive(outputs, "yuna")
    end

    test "a confiding threshold of zero admits characters without a relationship" do
      state =
        Runtime.demo_state()
        |> Tuning.put(:autonomy, :trust_threshold, 0)
        |> State.update_relationship("mina", "yuna", &%{&1 | trust: 0})
        |> State.update_character_state("mina", &%{&1 | loneliness: 70})

      {state, _outputs} = dispatch!(state, Event.gift_received("user", "mina", "flower"))
      {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))

      assert %{type: :gossip_shared, from: "mina", to: "haru"} =
               Enum.find(step.events, &(&1.type == :gossip_shared))
    end
  end
end
