defmodule Aethrion.MixProject do
  use Mix.Project

  def project do
    [
      app: :aethrion,
      version: "0.1.0-alpha",
      elixir: "~> 1.19",
      description: "A deterministic social simulation runtime for persistent AI characters.",
      package: package(),
      source_url: "https://github.com/simulacre7/aethrion",
      homepage_url: "https://github.com/simulacre7/aethrion",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/simulacre7/aethrion"
      }
    ]
  end
end
