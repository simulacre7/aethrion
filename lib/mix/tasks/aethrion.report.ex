defmodule Mix.Tasks.Aethrion.Report do
  @shortdoc "Renders a scenario as a self-contained HTML report"

  @moduledoc """
  Runs a scenario and writes a self-contained HTML report: cast, feelings over
  time, the relationship graph, the timeline with dialogue, and expectations.

      mix aethrion.report priv/scenarios/01_the_flower.json
      mix aethrion.report my_scenario.json --out tmp/report.html
      mix aethrion.report --all --out-dir tmp/reports

  Options:

  - `--out` - output file (default: `tmp/<scenario file name>.html`)
  - `--all` - render every bundled scenario
  - `--out-dir` - directory for `--all` (default: `tmp/reports`)
  - `--locale ko` - the report in Korean (scenario text stays as written)
  """

  use Mix.Task

  alias Aethrion.{Report, Scenario}

  @switches [out: :string, all: :boolean, out_dir: :string, locale: :string]

  @usage "mix aethrion.report PATH [--out FILE] [--locale en|ko] | --all [--out-dir DIR]"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, paths} = Aethrion.CLI.TaskArgs.parse!(args, @switches, @usage, 1)

    targets =
      case {opts[:all], paths} do
        {true, _paths} ->
          dir = Keyword.get(opts, :out_dir, "tmp/reports")

          Enum.map(
            Scenario.bundled(),
            &{&1, Path.join(dir, Path.basename(&1, ".json") <> ".html")}
          )

        {_all, [path]} ->
          default = Path.join("tmp", Path.basename(path, ".json") <> ".html")
          [{path, Keyword.get(opts, :out, default)}]

        _other ->
          Mix.raise("usage: #{@usage}")
      end

    Enum.each(targets, fn {path, out} ->
      with {:ok, scenario} <- Scenario.load(path),
           {:ok, result} <- Scenario.run(scenario) do
        Aethrion.CLI.TaskArgs.write!(out, Report.html(result, locale: locale(opts[:locale])))
        Mix.shell().info("#{scenario.name} -> #{out}")

        unless Scenario.passed?(result) do
          failed = Enum.count(result.checks, &(not &1.passed?))
          Mix.shell().error("  #{failed} expectation(s) not met; see the report's last section")
        end
      else
        {:error, error} -> Mix.raise("could not render #{path}: #{Aethrion.Error.format(error)}")
      end
    end)
  end

  defp locale(nil), do: :en
  defp locale("en"), do: :en
  defp locale("ko"), do: :ko
  defp locale(other), do: Mix.raise("unsupported locale #{inspect(other)}; use en or ko")
end
