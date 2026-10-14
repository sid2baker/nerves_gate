%{
  configs: [
    %{
      name: "default",
      files: %{included: ["{lib,dev,test}/**/*.{ex,exs}"]},
      plugins: [{ExSlop, []}],
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {ExSlop.Check.Readability.NarratorDoc, false}
      ]
    }
  ]
}
