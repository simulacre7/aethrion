defmodule Aethrion.ReviewRegressionsTest do
  # Regressions from the review of PR #2 (f4a9a94): each was reproduced here
  # before it was fixed.
  use ExUnit.Case, async: false

  alias Aethrion.{API, Event, Interpreter, Runtime, State, Worlds}
  alias Aethrion.LLM.CLI

  # An interpreter that takes its time.
  defmodule Sleepy do
    @behaviour Aethrion.Interpreter
    @impl true
    def interpret(request, opts) do
      Process.sleep(Keyword.fetch!(opts, :ms))
      Aethrion.Interpreter.Rules.interpret(request, [])
    end
  end

  defp cast_data(name), do: "priv/casts/#{name}.json" |> File.read!() |> Jason.decode!()

  defp cast(name) do
    {:ok, state} = name |> cast_data() |> State.parse()
    state
  end

  describe "1. work a cast can ask for is bounded" do
    test "dice counts and sizes have limits a cast cannot exceed" do
      for {stat, value} <- [
            {"damage_dice", 1_000_000_000},
            {"damage_die", 1_000_000},
            {"heal_dice", 500}
          ] do
        data = put_in(cast_data("den"), ["stats", "user", stat], value)
        assert {:error, %{message: message}} = State.parse(data), stat
        assert message =~ stat
      end

      data = put_in(cast_data("den"), ["tuning", "combat", "potion_dice"], 10_000)
      assert {:error, %{message: message}} = State.parse(data)
      assert message =~ "potion_dice"
    end

    test "a state built around the checks still rolls a bounded number of dice" do
      den = cast("den")
      wild = %{den | stats: put_in(den.stats, ["user", "damage_dice"], 1_000_000_000)}
      {:ok, step} = Runtime.step(wild, Event.attack("user", "dire_wolf"))
      [blow | _] = for %{type: :combat} = o <- step.outputs, do: o
      assert length(Map.get(blow, :dice_rolls, [])) <= 40
    end

    test "a simulation is limited in time and in how many run at once" do
      assert Aethrion.Simulator.limits() == %{timeout_ms: 10_000, concurrent: 2}

      slow = [interpreter: Sleepy, interpreter_opts: [ms: 2_000], timeout_ms: 200]
      route = %{name: "slow", to: "seoyun", days: 1, script: "안녕"}
      summer = cast("summer")

      assert {:error, :timeout} = Aethrion.Simulator.run_limited(summer, [route], slow)

      busy =
        for _ <- 1..2,
            do:
              Task.async(fn ->
                Aethrion.Simulator.run_limited(
                  summer,
                  [route],
                  Keyword.put(slow, :timeout_ms, 1_000)
                )
              end)

      Process.sleep(100)
      assert {:error, :busy} = Aethrion.Simulator.run_limited(summer, [route], slow)
      Enum.each(busy, &Task.await(&1, 5_000))
    end
  end

  describe "2. a CLI that outlives its timeout is stopped" do
    @describetag :tmp_dir

    defp slow_cli(dir) do
      cli = Path.join(dir, "slow-cli")
      pids = Path.join(dir, "pids")

      File.write!(cli, """
      #!/bin/sh
      sleep 30 &
      echo "$$ $!" > #{pids}
      wait
      """)

      File.chmod!(cli, 0o755)
      {cli, pids}
    end

    defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

    defp read_pids(path) do
      Enum.find_value(1..50, fn _ ->
        case File.read(path) do
          {:ok, text} when text != "" -> String.split(text)
          _ -> Process.sleep(50) && nil
        end
      end)
    end

    defp eventually_dead?(pid),
      do: Enum.any?(1..40, fn _ -> not alive?(pid) || (Process.sleep(50) && false) end)

    test "on timeout, the process and its children are gone", %{tmp_dir: dir} do
      {cli, pids} = slow_cli(dir)
      # Long enough for the script to start under load, and write its pids.
      assert {:error, :timeout} = CLI.complete("s", "u", command: cli, timeout: 2_000)
      [shell, child] = read_pids(pids)
      assert eventually_dead?(shell)
      assert eventually_dead?(child)
    end

    test "when the caller goes away, the process goes too", %{tmp_dir: dir} do
      {cli, pids} = slow_cli(dir)
      caller = spawn(fn -> CLI.complete("s", "u", command: cli, timeout: 60_000) end)
      [shell, child] = read_pids(pids)
      Process.exit(caller, :kill)
      assert eventually_dead?(shell)
      assert eventually_dead?(child)
    end
  end

  describe "3. a malformed milestone is an error with a path, not a crash" do
    test "from, to, and says are checked" do
      for {milestone, path} <- [
            {%{
               "id" => "m",
               "from" => %{},
               "says" => 42,
               "when" => [%{"clock" => true, "at_least" => 0}]
             }, "from"},
            {%{
               "id" => "m",
               "from" => "hana",
               "says" => 42,
               "when" => [%{"clock" => true, "at_least" => 0}]
             }, "says"},
            {%{
               "id" => "m",
               "from" => "ghost",
               "says" => "hi",
               "when" => [%{"clock" => true, "at_least" => 0}]
             }, "ghost"},
            {%{
               "id" => "m",
               "from" => "hana",
               "to" => 7,
               "says" => "hi",
               "when" => [%{"clock" => true, "at_least" => 0}]
             }, "to"}
          ] do
        data = put_in(cast_data("academy"), ["story", "milestones"], [milestone])
        assert {:error, %{message: message}} = State.parse(data)
        assert message =~ path
      end
    end
  end

  # A model stand-in that answers with a fixed reply.
  defmodule Fixed do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, opts), do: {:ok, Keyword.fetch!(opts, :reply)}
  end

  defp read(state, to, text, reply) do
    Interpreter.read(state, "user", to, text,
      interpreter: Interpreter.LLM,
      interpreter_opts: [adapter: Fixed, adapter_opts: [reply: reply]]
    )
  end

  describe "4. a model's heal is made valid the same way as the rules', or the rules read it" do
    test "drinking a potion uses one" do
      den = put_in(cast("den").stats["user"]["hp"], 9)

      assert {:ok, [%{event: %{type: :heal, to: "user", item: "potion"} = event}], %{status: :ok}} =
               read(
                 den,
                 "sera",
                 "포션을 마신다",
                 ~s({"readings": [{"does": "heal", "target": "user", "confidence": 0.99}]})
               )

      assert {:ok, _step} = Runtime.step(den, event)
    end

    test "a heal that cannot be made valid falls back to the rules" do
      unhurt = cast("den")

      assert {:ok, _readings, %{status: :fallback, reason: {:invalid_event, _}}} =
               read(
                 unhurt,
                 "sera",
                 "포션을 마신다",
                 ~s({"readings": [{"does": "heal", "target": "user"}]})
               )
    end
  end

  describe "5. answers outside the schema are not taken" do
    test "no fight moves without a fight" do
      for does <- ~w(defend heal attack flee) do
        assert {:ok, _readings, %{status: :fallback, reason: :no_fight}} =
                 read(cast("summer"), "seoyun", "막는다", ~s({"readings": [{"does": "#{does}"}]})),
               does
      end
    end

    test "confidence is a number from 0 to 1" do
      for confidence <- ["99", "-0.1", ~s("high")] do
        assert {:ok, _readings, %{status: :fallback, reason: {:invalid_confidence, _}}} =
                 read(
                   cast("summer"),
                   "seoyun",
                   "안녕",
                   ~s({"readings": [{"does": "talk", "tone": "warm", "confidence": #{confidence}}]})
                 ),
               confidence
      end
    end
  end

  describe "7. bad simulation routes are 400s" do
    setup do
      start_supervised!({Worlds, name: Worlds.Test.Review, world: fn _key -> [] end})
      pid = start_supervised!({API, worlds: Worlds.Test.Review, port: 0})
      %{base: "http://127.0.0.1:#{API.port(pid)}"}
    end

    defp post(url, body) do
      {:ok, {{_v, status, _r}, _h, response}} =
        :httpc.request(
          :post,
          {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)},
          [],
          body_format: :binary
        )

      {status, Jason.decode!(response)}
    end

    test "a name that is not text, and a character the cast does not have", %{base: base} do
      cast = cast_data("summer")
      route = %{"to" => "seoyun", "days" => 3, "script" => "안녕"}

      assert {400, %{"error" => %{"message" => message}}} =
               post(base <> "/casts/simulate", %{
                 "cast" => cast,
                 "routes" => [Map.put(route, "name", %{})]
               })

      assert message =~ "name"

      assert {400, %{"error" => %{"message" => message}}} =
               post(base <> "/casts/simulate", %{
                 "cast" => cast,
                 "routes" => [%{route | "to" => "ghost"}]
               })

      assert message =~ "ghost"
    end

    # Second review: it was a 503 (an ArithmeticError mid-fight).
    test "a cast with a number too large to fight with", %{base: base} do
      cast = cast_data("den") |> put_in(["stats", "user", "hp"], Integer.pow(10, 400))
      route = %{"name" => "r", "to" => "sera", "days" => 1, "script" => "I defend"}

      assert {400, %{"error" => %{"message" => message}}} =
               post(base <> "/casts/simulate", %{"cast" => cast, "routes" => [route]})

      assert message =~ "stats.user.hp"
    end
  end

  describe "second review: a CLI model is waited for as long by the world as by the API" do
    test "the world's line timeout is the API's render timeout" do
      alias Mix.Tasks.Aethrion.Serve

      for adapter <- [Aethrion.LLM.CLI, Aethrion.LLM.Anthropic] do
        [expression: expression] = Serve.expression(adapter, [], nil)
        api = Serve.reading(adapter, [], [], "model")
        assert expression[:timeout] == api[:render_timeout]
      end
    end
  end

  describe "second review: a healer drinking a potion" do
    test "heals by the potion's dice, not their own spell's" do
      {:ok, den} =
        "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()

      den = %{
        den
        | stats: Map.update!(den.stats, "sera", &Map.merge(&1, %{"hp" => 5, "potions" => 1}))
      }

      {:ok, step} =
        Aethrion.Runtime.step(den, Aethrion.Event.heal("sera", "sera", item: "potion"))

      [healed | _] = for %{type: :combat, kind: :healed} = o <- step.outputs, do: o
      assert healed.dice == "2d4+2"
      assert Aethrion.State.stat(step.state, "sera", "potions") == 0

      # Without an item, a healer's own healing is still her spell.
      {:ok, den_hurt} =
        {:ok, %{den | stats: Map.update!(den.stats, "doyun", &Map.put(&1, "hp", 5))}}

      {:ok, step} = Aethrion.Runtime.step(den_hurt, Aethrion.Event.heal("sera", "doyun"))
      [healed | _] = for %{type: :combat, kind: :healed} = o <- step.outputs, do: o
      assert healed.dice == "1d8+3"
    end
  end

  describe "second review: numbers too large to fight with" do
    defp huge, do: Integer.pow(10, 400)

    test "are refused when the cast is read, with where they are" do
      {:ok, den} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> then(&{:ok, &1})

      data = put_in(den, ["stats", "user", "hp"], huge())
      assert {:error, %{details: %{path: ["stats", "user", "hp"]}}} = Aethrion.State.parse(data)

      data =
        put_in(den, ["story", "decide_when"], [%{"stat" => ["user", "hp"], "at_most" => huge()}])

      assert {:error, %{message: message}} = Aethrion.State.parse(data)
      assert message =~ "at_most"

      data = Map.put(den, "story", %{"activities" => %{"rest" => %{"hp" => huge()}}})
      assert {:error, _error} = Aethrion.State.parse(data)
    end

    test "the largest allowed still fight" do
      {:ok, den} =
        "priv/casts/den.json"
        |> File.read!()
        |> Jason.decode!()
        |> put_in(["stats", "user"], %{
          "hp" => 1_000_000_000,
          "max_hp" => 1_000_000_000,
          "ac" => 16
        })
        |> Aethrion.State.parse()

      assert {:ok, _step} = Aethrion.Runtime.step(den, Aethrion.Event.defend("user"))
    end
  end

  describe "second review, checked again" do
    test "a heal's amount is bounded like any number" do
      {:ok, den} =
        "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()

      den = %{den | stats: Map.update!(den.stats, "user", &Map.put(&1, "hp", 5))}

      assert {:error, %{code: :invalid_event}} =
               Aethrion.Runtime.step(
                 den,
                 Aethrion.Event.heal("sera", "user", amount: Integer.pow(10, 400))
               )
    end

    test "a healer of her own does not reach for a potion unasked" do
      {:ok, den} =
        "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()

      den = %{den | stats: Map.update!(den.stats, "sera", &Map.put(&1, "potions", 1))}
      assert Aethrion.Combat.heal_item(den, "sera", "치료한다") == nil
      assert Aethrion.Combat.heal_item(den, "sera", "포션을 마신다") == "potion"
      # Someone with no healing of their own still does.
      den = %{den | stats: Map.update!(den.stats, "doyun", &Map.put(&1, "potions", 1))}
      assert Aethrion.Combat.heal_item(den, "doyun", "치료한다") == "potion"
    end
  end
end
