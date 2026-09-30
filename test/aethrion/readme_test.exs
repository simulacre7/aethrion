defmodule Aethrion.ReadmeTest do
  # The READMEs quote real demo output; keep them honest.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  defp quoted_blocks(path, marker) do
    ~r/```txt\n(.*?)```/s
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&String.contains?(&1, marker))
  end

  test "the drama excerpt in both READMEs is real output" do
    output = capture_io(fn -> Mix.Tasks.Demo.Drama.run([]) end) |> plain()

    for readme <- ["README.md", "README.ko.md"],
        block <- quoted_blocks(readme, "EVENT    user gives Mina a flower"),
        line <- String.split(block, "\n", trim: true) do
      assert output =~ String.trim(line),
             "#{readme} quotes a line the demo no longer prints: #{line}"
    end
  end

  test "the context excerpt in the README is real output" do
    input =
      "gift user mina flower observed_by yuna\nsay yuna sorry I forgot about you\ncontext yuna\nquit\n"

    output =
      capture_io(input, fn -> Mix.Tasks.Demo.Interactive.run(["--no-status"]) end) |> plain()

    [block] = quoted_blocks("README.md", "user> context yuna")
    [_before, context] = String.split(block, "user> context yuna\n")

    for line <- String.split(context, "\n", trim: true) do
      assert output =~ String.trim(line),
             "README quotes a context line the demo no longer prints: #{line}"
    end
  end
end
