defmodule Aethrion.MixProject do
  use Mix.Project

  @version "0.2.0-alpha"
  @source_url "https://github.com/simulacre7/aethrion"

  def project do
    [
      app: :aethrion,
      version: @version,
      elixir: "~> 1.19",
      description: "A deterministic social simulation runtime for persistent AI characters.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:mix, :ex_unit, :inets, :ssl, :public_key]],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  # dev/ holds the demo tasks (mix demo.*). They run in this repository but are
  # not part of the package, so projects depending on Aethrion don't get them.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv docs mix.exs README.md README.ko.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      skip_undefined_reference_warnings_on: ["README.md"],
      extras: [
        "README.md",
        "docs/tutorial.md",
        "docs/tutorial.ko.md",
        "docs/concept.md",
        "docs/architecture.md",
        "docs/rules.md",
        "docs/expression.md",
        "docs/scenarios.md",
        "docs/api.md",
        "docs/faq.md",
        "docs/roadmap.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Runtime: [
          Aethrion,
          Aethrion.Runtime,
          Aethrion.Step,
          Aethrion.Event,
          Aethrion.Output,
          Aethrion.Error
        ],
        "World state": [
          Aethrion.State,
          Aethrion.Character,
          Aethrion.CharacterState,
          Aethrion.Relationship,
          Aethrion.Memory,
          Aethrion.Memories
        ],
        "Rules & explainability": [
          Aethrion.Rule,
          Aethrion.Pipeline,
          Aethrion.Transition,
          Aethrion.Trace,
          Aethrion.Explain,
          ~r/Aethrion\.Rules\./
        ],
        "Expression & LLMs": [
          Aethrion.Expression,
          Aethrion.Expression.Request,
          Aethrion.Expression.Templates,
          Aethrion.Expression.Prompt,
          Aethrion.Intent,
          Aethrion.Intent.Request,
          ~r/Aethrion\.LLM\./
        ],
        "OTP runtime": [Aethrion.World, Aethrion.RuntimeServer, Aethrion.Scheduler],
        "Scenarios & persistence": [
          Aethrion.Scenario,
          Aethrion.Scenario.Result,
          Aethrion.Report,
          Aethrion.Journal,
          ~r/Aethrion\.Persistence/
        ]
      ]
    ]
  end
end
