defmodule PopcornDemo.MixProject do
  use Mix.Project

  @popcorn_version "0.4.0-next.7"

  def project do
    [
      app: :popcorn_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      # Popcorn boots the entrypoint application's mod on the browser VM.
      # The smoke child computes pure smalt-layer results; on the browser VM
      # it reports through Popcorn.JS, under plain mix test/host mix run it
      # just returns values.
      mod: {PopcornDemo.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:popcorn, @popcorn_version},
      {:jason, "~> 1.4"}
    ]
  end
end
