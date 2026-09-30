# Credo's defaults, with room for rule decision tables (a derive/1 that maps
# thresholds to a name is naturally branchy) and one more level of nesting.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "dev/", "test/", "mix.exs"], excluded: []},
      checks: %{
        extra: [
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]}
        ]
      }
    }
  ]
}
