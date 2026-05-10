defmodule DependabotDependencyGrapher.MixProject do
  use Mix.Project

  def project do
    [
      app: :dependabot_dependency_grapher,
      version: "0.1.0",
      elixir: "~> 1.18",
      lockfile: Path.expand("mix.lock", __DIR__),
      deps: [{:sbom, "~> 0.10.0"}]
    ]
  end
end
