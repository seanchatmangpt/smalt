defmodule Smalt.MixProject do
  use Mix.Project

  @version "26.10.14"

  def project do
    [
      app: :smalt,
      version: @version,
      elixir: "~> 1.18 or ~> 1.19 or ~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  defp releases do
    [
      smalt: [
        version: @version,
        applications: [smalt: :permanent],
        include_executables_for: [:unix],
        strip_beams: [compress: true]
      ]
    ]
  end

  defp aliases do
    [
      "smalt.gen": [
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-substrate-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl " <>
          "--query control_plane=../ggen-marketplace/packs/smalt-substrate-pack/queries/control_plane.rq " <>
          "--query payload_rules=../ggen-marketplace/packs/smalt-substrate-pack/queries/payload_rules.rq " <>
          "--template ../ggen-marketplace/packs/smalt-substrate-pack/templates/registry.ex.eex " <>
          "--out lib/smalt/registry.ex --engine sparql",
        # Replay identity: the generated artifact must be canonical-formatted
        # so `mix smalt.gen` replay is byte-identical (fenced by
        # test/smalt_registry_replay_identity_test.exs).
        "format lib/smalt/registry.ex"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key, :xmerl],
      mod: {Smalt.Application, []}
    ]
  end

  defp description do
    "Pure-Elixir BEAM-native local substrate emulating an ARM-style control " <>
      "plane and hyperscaler data-plane wire protocols for offline testing."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/seanchatmangpt/smalt"},
      # B6: key material must never ship. The gate is the physical tree, not
      # these patterns: hex applies exclude_patterns per-`files:`-entry,
      # `**` does not traverse dot-directories, and the dev keys have no
      # .pem extension — so these three patterns never match anything
      # (verified: they were dead in v26.10.13/14 builds). The keys were
      # removed from lib/ (receipt chain relocated to test/fixtures/); the
      # acceptance gate is the inner contents.tar.gz grep == 0 in
      # docs/PUBLISH_CHECK.md, not glob semantics.
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md),
      exclude_patterns: ["**/.ggen/**", "**/keys/**", "**/*key*.pem"]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:cors_plug, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:ash, "~> 3.33", optional: true},
      {:ash_graphlaw, path: "../ash_graphlaw", only: :dev, optional: true},
      # Semantic projection (lane: semantic projection). Path deps per house
      # pattern; `only:` widened from the spec's :dev to [:dev, :test] so the
      # gate (`mix test test/semantic_projection_test.exs`, MIX_ENV=test) can
      # compile them. Disclosed in docs/SEMANTIC_PROJECTION.md.
      {:ash_r2rml, path: "../ash_r2rml", only: [:dev, :test], optional: true},
      {:ash_ex4pm, path: "../ash_ex4pm", only: [:dev, :test], optional: true},
      {:ggen_igniter, path: "../ggen_igniter", only: :dev, optional: true}
    ]
  end
end
