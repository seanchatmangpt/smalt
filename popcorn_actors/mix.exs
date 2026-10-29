defmodule PopcornActors.MixProject do
  use Mix.Project

  @popcorn_version "0.4.0-next.7"

  def project do
    [
      app: :popcorn_actors,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Pruned bundle surface: nothing beyond what Popcorn requires plus this app.
  # No :logger, no :jason, no :crypto/:ssl/:inets (core wasm runtime has no
  # crypto — witnessed in popcorn_demo/mix.exs note).
  def application do
    [
      mod: {PopcornActors.Application, []},
      extra_applications: []
    ]
  end

  defp deps do
    [
      {:popcorn, @popcorn_version}
    ]
  end
end
