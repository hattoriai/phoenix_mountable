%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: []},
      strict: true,
      checks: %{
        extra: [
          # Macro-generated code and SQL builders read better with a level
          # more than the default.
          {Credo.Check.Refactor.Nesting, max_nesting: 3},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 18}
        ],
        disabled: [
          # Fully qualified names are kept where a module is used once, as in
          # Phoenix's own code.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
