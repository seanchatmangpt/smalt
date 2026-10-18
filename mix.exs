defmodule Smalt.MixProject do
  use Mix.Project

  @version "26.10.16"

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
      # Engine law (2026-10-17): ggen_igniter's query engine is FIXED to
      # graphlaw (--engine flag removed upstream); smalt passes no --engine.
      # W2a (2026-10-17): the `smalt.gen` alias moved to
      # lib/mix/tasks/smalt.gen.ex (Mix.Tasks.Smalt.Gen). The alias chain
      # invoking `ggen_igniter.sync` N times only executed the FIRST
      # stanza (Mix.Task.run/2 skips a task already run in the same VM) —
      # the later stanzas silently skipped and left stale artifacts.
      # Mix.Task.rerun/2 in the task forces every stanza.
      "test.cross_seat": ["test --only cross_seat test/auth_enforce_test.exs"],
      "test.amqp_wire": ["test --include amqp_wire"],
      "test.compliance": ["test --include amqp_wire test/compliance_test.exs"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key, :xmerl, :wasmex],
      mod: {Smalt.Application, []}
    ]
  end

  # R164: dotted `test.*` aliases do not get Mix's automatic :test env
  # default (that only applies to the bare `test` task), so pin the env
  # explicitly via preferred_envs.
  def cli do
    [preferred_envs: ["test.cross_seat": :test, "test.amqp_wire": :test, "test.compliance": :test]]
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
      # docs/archive/PUBLISH_CHECK.md, not glob semantics.
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md),
      exclude_patterns: ["**/.ggen/**", "**/keys/**", "**/*key*.pem"]
    ]
  end

  defp path_dep(app, path, opts) do
    if File.dir?(path) do
      [{app, [{:path, path} | opts]}]
    else
      []
    end
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:cors_plug, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:ash, "~> 3.33", optional: true}
    ] ++ path_dep(:ash_graphlaw, "../ash_graphlaw", only: :dev, optional: true)
      ++ path_dep(:ash_r2rml, "../ash_r2rml", only: [:dev, :test], optional: true)
      ++ path_dep(:ash_ex4pm, "../ash_ex4pm", only: [:dev, :test], optional: true)
      ++ path_dep(:ex4pm, "../ex4pm", override: true, optional: true)
      ++ path_dep(:ggen_igniter, "../ggen_igniter", only: :dev, optional: true)
      ++ [
      # ERRC Raise lane 6: property-based testing with shrinking (test-only
      # usage; declared env-prod because `ash` requires stream_data
      # non-optionally — Mix surface-convergence constraint, never packaged:
      # files: whitelist above excludes deps/).
      {:stream_data, "~> 1.2"},
      # Static security analysis (ERRC lane 8 Raise). Non-blocking first pass;
      # recipe `just sobelow` records, does not gate.
      {:sobelow, "~> 0.13", only: :dev, runtime: false},
      # Benchmarking (ERRC lane 2 Raise): benchee drives scripts/bench/benchee_runner.exs
      # (b7b/b8b/b9b rows) as the statistical counterpart to the hand-rolled
      # b7/b8/b9 timing loops (kept as falsifier records).
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false},
      # B-11 recon soak (docs/jira/v26.10.14/receipts/errc7-recon.md): BEAM-level
      # leak evidence (processes/binaries/atoms/ETS) that RSS alone cannot give.
      {:recon, "~> 2.5", only: :test},
      # WASM engine (lane 601, v26.10.16): pin mirrors ash_a2a mix.exs:522
      # ("~> 0.15.1") so graphlaw and affidavit share one wasmex identity.
      # Fail-closed host: {:error, :engine_unavailable} when artifact absent.
      {:wasmex, "~> 0.15.1"}
    ]
  end
end
