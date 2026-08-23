%{
  configs: [
    %{
      name: "default",
      checks: [{Credo.Check.Design.AliasUsage, false}]
    }
  ]
}
