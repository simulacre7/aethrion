defmodule Aethrion.MixTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  test "the interactive demo runs a scripted session" do
    input = """
    gift user mina flower observed_by yuna
    say yuna sorry I forgot about you
    tick 2
    why yuna
    context yuna
    memories yuna
    timeline
    undo
    bogus
    quit
    """

    output = capture_io(input, fn -> Mix.Tasks.Demo.Interactive.run([]) end) |> plain()

    assert output =~
             "INTENT   \"sorry I forgot about you\" -> apology_offered via Aethrion.LLM.FakeAdapter"

    assert output =~ "e1 observation: yuna.jealousy 0 -> 15"
    assert output =~ "Draft line:"
    assert output =~ "e3   time passes +2h"
    assert output =~ "undone"
    assert output =~ "ERROR unknown command"
    assert output =~ "bye"
  end

  test "the scripted and branch demos run" do
    assert capture_io(fn -> Mix.Tasks.Demo.Drama.run([]) end) |> plain() =~ "Haru comforts Yuna"

    assert capture_io(fn -> Mix.Tasks.Demo.Branches.run([]) end) |> plain() =~
             "Where Yuna ends up"
  end

  test "scenario task checks bundled scenarios" do
    output =
      capture_io(fn -> Mix.Tasks.Aethrion.Scenario.run(["--all", "--quiet"]) end) |> plain()

    assert output =~ "The flower"
    assert output =~ "10/10 expectations met"
    refute output =~ "FAIL"
  end

  test "scenario task can emit json" do
    [path | _] = Aethrion.Scenario.bundled()
    output = capture_io(fn -> Mix.Tasks.Aethrion.Scenario.run([path, "--json"]) end)

    assert %{"passed" => true, "state" => %{"version" => 2}, "outputs" => [_ | _]} =
             Jason.decode!(output)
  end

  test "rules task lists the pipeline" do
    output = capture_io(fn -> Mix.Tasks.Aethrion.Rules.run([]) end) |> plain()

    assert output =~ "gift_received"
    assert output =~ "after every event (reactive)"
    assert output =~ "1. mood"
  end

  test "report task writes html" do
    out =
      Path.join(System.tmp_dir!(), "aethrion-report-#{System.unique_integer([:positive])}.html")

    on_exit(fn -> File.rm(out) end)
    [path | _] = Aethrion.Scenario.bundled()

    capture_io(fn -> Mix.Tasks.Aethrion.Report.run([path, "--out", out]) end)

    assert File.read!(out) =~ "<h2>Timeline</h2>"
  end

  test "characters who are here witness what is said" do
    input =
      "here haru\nmessage user yuna hostile leave me alone\nhere none\ngift user mina pin\nquit\n"

    output =
      capture_io(input, fn -> Mix.Tasks.Demo.Interactive.run(["--no-status"]) end) |> plain()

    assert output =~ "present: Haru"
    assert output =~ "user -> Yuna (hostile): leave me alone (seen by Haru)"
    assert output =~ "Haru saw user be hostile to Yuna and trusts user less"
    assert output =~ "user gives Mina a pin\n"
  end

  test "opinion shows how one character sees another" do
    input =
      "here haru\nmessage user yuna hostile go away\nmessage user yuna hostile I said go\ntick 120\nopinion haru user\nquit\n"

    output =
      capture_io(input, fn -> Mix.Tasks.Demo.Interactive.run(["--no-status"]) end) |> plain()

    assert output =~ "Opinion  how Haru sees user"

    assert output =~
             ~r/believes\s+haru knows user has been hostile to yuna 2 times\.\s+\(reputation\)/
  end

  @tag :tmp_dir
  test "journal task compacts and archives", %{tmp_dir: dir} do
    path = Path.join(dir, "world.jsonl")
    archive = Path.join(dir, "old.jsonl")
    state = Aethrion.Runtime.demo_state()
    :ok = Aethrion.Journal.create(path, state)
    {:ok, step} = Aethrion.Runtime.step(state, Aethrion.Event.time_tick("t", hours: 3))
    :ok = Aethrion.Journal.append(path, step.event)

    output =
      capture_io(fn ->
        Mix.Tasks.Aethrion.Journal.run([path, "--compact", "--archive", archive])
      end)
      |> plain()

    assert output =~ "compacted 1 event into the starting state"
    assert {:ok, compacted, []} = Aethrion.Journal.read(path)
    assert compacted == step.state
    assert {:ok, _state, [_event]} = Aethrion.Journal.read(archive)

    assert_raise Mix.Error, "--archive only applies with --compact", fn ->
      Mix.Tasks.Aethrion.Journal.run([path, "--archive", Path.join(dir, "x.jsonl")])
    end
  end

  @tag :tmp_dir
  test "report task renders every scenario, in Korean if asked", %{tmp_dir: dir} do
    capture_io(fn ->
      Mix.Tasks.Aethrion.Report.run(["--all", "--out-dir", dir, "--locale", "ko"])
    end)

    files = Path.wildcard(Path.join(dir, "*.html"))
    assert length(files) == length(Aethrion.Scenario.bundled())
    assert File.read!(Path.join(dir, "01_the_flower.html")) =~ ~s(<ul class="digest" lang="ko">)

    assert_raise Mix.Error, ~r/unsupported locale "fr"/, fn ->
      Mix.Tasks.Aethrion.Report.run([hd(Aethrion.Scenario.bundled()), "--locale", "fr"])
    end

    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Aethrion.Report.run([]) end
  end

  test "the interactive demo records and reports a session" do
    dir = Path.join(System.tmp_dir!(), "aethrion-session-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    input = """
    gift user mina flower observed_by yuna
    tick 2
    record #{dir}/session.json
    report #{dir}/session.html
    quit
    """

    capture_io(input, fn -> Mix.Tasks.Demo.Interactive.run(["--no-status"]) end)

    assert {:ok, scenario} = Aethrion.Scenario.load(Path.join(dir, "session.json"))
    assert {:ok, result} = Aethrion.Scenario.run(scenario)
    assert Aethrion.Scenario.passed?(result)
    assert File.read!(Path.join(dir, "session.html")) =~ "Interactive session"
  end
end
