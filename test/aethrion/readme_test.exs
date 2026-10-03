defmodule Aethrion.ReadmeTest do
  # The tour docs quote real demo output; keep them honest.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  @tours ["docs/tour.md", "docs/tour.ko.md"]

  defp quoted_blocks(path, marker) do
    blocks =
      ~r/```txt\n(.*?)```/s
      |> Regex.scan(File.read!(path), capture: :all_but_first)
      |> List.flatten()
      |> Enum.filter(&String.contains?(&1, marker))

    assert blocks != [], "#{path} no longer quotes the block with: #{marker}"
    blocks
  end

  test "the drama excerpt in both tours is real output" do
    output = capture_io(fn -> Mix.Tasks.Demo.Drama.run([]) end) |> plain()

    for readme <- @tours,
        block <- quoted_blocks(readme, "EVENT    user gives Mina a flower"),
        line <- String.split(block, "\n", trim: true) do
      assert output =~ String.trim(line),
             "#{readme} quotes a line the demo no longer prints: #{line}"
    end
  end

  test "the word-gets-around excerpt in both tours is real output" do
    path =
      Enum.find(Aethrion.Scenario.bundled(), &String.ends_with?(&1, "12_word_gets_around.json"))

    output = capture_io(fn -> Mix.Tasks.Aethrion.Scenario.run([path]) end) |> plain()

    for readme <- @tours,
        block <- quoted_blocks(readme, "You always ruin everything. (seen by Haru)"),
        line <- String.split(block, "\n", trim: true) do
      assert output =~ String.trim(line),
             "#{readme} quotes a line the scenario no longer prints: #{line}"
    end
  end

  test "the context excerpt in the tour is real output" do
    input =
      "gift user mina flower observed_by yuna\nsay yuna sorry I forgot about you\ncontext yuna\nquit\n"

    output =
      capture_io(input, fn -> Mix.Tasks.Demo.Interactive.run(["--no-status"]) end) |> plain()

    [block] = quoted_blocks("docs/tour.md", "user> context yuna")
    [_before, context] = String.split(block, "user> context yuna\n")

    for line <- String.split(context, "\n", trim: true) do
      assert output =~ String.trim(line),
             "docs/tour.md quotes a context line the demo no longer prints: #{line}"
    end
  end

  test "the recorded demo transcript is what the demo prints now" do
    transcript = File.read!("assets/demo/interactive-demo.txt")

    commands =
      for "user> " <> command <- String.split(transcript, "\n"), command != "", do: command

    output =
      capture_io(Enum.join(commands, "\n") <> "\n", fn ->
        Mix.Tasks.Demo.Interactive.run(["--no-status"])
      end)
      |> plain()

    for line <- String.split(transcript, "\n", trim: true),
        not String.starts_with?(line, "user> ") do
      assert output =~ line,
             "the recorded transcript shows a line the demo no longer prints: #{line}"
    end
  end

  test "the Livebook tour runs, apart from installing and rendering" do
    [_install | cells] =
      ~r/```elixir\n(.*?)```/s
      |> Regex.scan(File.read!("notebooks/tour.livemd"), capture: :all_but_first)
      |> List.flatten()

    code =
      cells
      |> Enum.join("\n")
      |> String.replace("|> Kino.HTML.new()", "|> byte_size()")

    capture_io(fn ->
      {html_size, _binding} = Code.eval_string(code)
      assert html_size > 10_000
    end)
  end
end
