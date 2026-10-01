defmodule Aethrion.InterpreterEvalTest do
  use ExUnit.Case, async: true

  alias Aethrion.Interpreter.Eval

  # The built-in rules read about six in ten labeled lines the way a person
  # means them (the rest is what a model is for); this keeps them from
  # getting worse unnoticed.
  @baseline 0.6

  test "the rules on the labeled Korean set" do
    {:ok, cases} = Eval.load("priv/eval/interpret.ko.json")
    assert length(cases) >= 150

    report = Eval.run(cases)
    assert report.score >= @baseline, "the rules read #{report.passed}/#{report.total}"
    assert Map.keys(report.by_as) |> Enum.sort() == ~w(activity combat gift talk)
  end
end
