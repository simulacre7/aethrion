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
        assert {:error, {:invalid_state_data, ^path, _reason}} = State.parse(data)
      end
    end

    test "a corrupted snapshot stops the server instead of being overwritten" do
      path = Path.join(System.tmp_dir!(), "aethrion-corrupt-#{System.unique_integer()}.json")
      File.write!(path, ~s({"characters": [{"id": "a"}]}))
      on_exit(fn -> File.rm(path) end)

      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:error, {:invalid_snapshot, {:invalid_state_data, _path, _reason}}} =
                 RuntimeServer.start_link(persistence: {JsonFile, path: path})
      end)

      assert File.read!(path) == ~s({"characters": [{"id": "a"}]})
    end

    test "odd scenario values produce errors or readable descriptions, not crashes" do
      assert {:error, {:invalid_field, "name", 1.5}} = Scenario.from_data(%{"name" => 1.5})

      assert {:error, {:invalid_world, ["characters", 0, "traits"], _}} =
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
end
