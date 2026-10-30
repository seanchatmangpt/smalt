defmodule Smalt.MixProject do
  use Mix.Project

  @version "26.10.25"

  def project do
    [
      app: :smalt,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # FONDRUNNER: parallel Erlang module family compiled in-repo (lib/smalt/pipeline)
      # STORE-4: operator-mandated 16-partition Erlang store family (src/)
      erlc_paths: ["lib/smalt/pipeline", "src"],
      description: description(),
      package: package(),
      source_url: "https://github.com/seanchatmangpt/smalt",
      homepage_url: "https://github.com/seanchatmangpt/smalt",
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
    [
      preferred_envs: [
        "test.cross_seat": :test,
        "test.amqp_wire": :test,
        "test.compliance": :test
      ]
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
      # docs/archive/PUBLISH_CHECK.md, not glob semantics.
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md),
      exclude_patterns: ["**/.ggen/**", "**/keys/**", "**/*key*.pem"]
    ]
  end

  defp deps do
    [
      # GL28-2: the deterministic turnstile — admission gate before any
      # control-plane state mutation (path dep on the sibling checkout).
      # dev/test-gated: zero live code references to GraphlawEx.* modules
      # exist in lib/ (the admission gate was inlined into
      # Smalt.GraphlawEx.AdmissionGate; only doc strings mention the dep).
      # Required for `mix hex.build` — path deps outside dev/test are fatal
      # to packaging (publish-dry gate 1, r03; same pattern as ggen_igniter).
      {:graphlaw_ex, path: "../graphlaw/graphlaw_ex", only: [:dev, :test]},
      {:bandit, "~> 1.6"},
      # v26.10.29 T-02 lane: azure_cache.ex drives Azure Redis Enterprise via
      # Cachex (in-process cache engine standing in for the redis wire face).
      # Version per the T-06 receipt (WINDOW_HANDOFF.md:37,97).
      {:cachex, "~> 4.0"},
      # T-07 APIM gateway outbound (r16): promoted per the conditional gate in
      # apim_gateway.ex — Code.ensure_loaded?(Finch) flips the fast path on.
      {:finch, "~> 0.24"},
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
      {:ash_ex4pm, "~> 26.10.1", only: [:dev, :test], optional: true},
      # Process-intelligence + attestation engine (operator ruling,
      # v26.10.16): permanent RUNTIME dep — it is the OCEL event
      # sink / POWL discovery+conformance backend, not a manufacturing-time
      # tool. Elixir compat: ex4pm "~> 1.17" satisfies smalt's
      # "~> 1.20".
      # B1 CLOSED (2026-10-17, operator ruling "hex.pm only"): the path dep
      # is retired — smalt resolves ex4pm from hex.pm like every other dep.
      # ex4pm 26.10.8 hex dry-build verified (PUBLISH_RECORD.md, lane G1):
      # `mix hex.build -o /tmp/ex4pm-26.10.8.tar` exit 0, checksum
      # 038d538135c9bfe5a9ac266ed5a87780dbe56ce91eb1a7cb188e1833726b9564,
      # 468 files, zero plts/_build/deps leakage. REQUIRES ex4pm 26.10.8
      # published to hex (operator: cd ~/ex4pm && mix hex.publish) before
      # `mix deps.get` can resolve this pin.
      # override dropped 2026-10-17: with the hex pin resolved there is no
      # conflicting path dep in prod scope (ash_ex4pm is dev/test-only), and
      # `mix hex.build` refuses overridden deps.
      # "~> 26.10.1" (not .8): hex ash_ex4pm 26.10.4 (latest) pins
      # {:ex4pm, "== 26.10.1"}, so .8 is unsatisfiable tree-wide until
      # ash_ex4pm relaxes its pin (sibling-repo release, operator-gated).
      # 26.10.8 is a version-alignment release with Public contract UNCHANGED
      # (its CHANGELOG), so .1 is functionally equivalent; the resolver picks
      # .8 automatically the moment the constraint allows.
      {:ex4pm, "~> 26.10.1"},
      {:ggen_igniter, path: "../ggen_igniter", only: :dev, optional: true},
      # smalt.gen.ash: extraction rides ggen_igniter (dev); AST synthesis rides
      # Igniter directly. Unconditional because lib/mix/tasks/*.ex compiles in
      # every env (release.sh does MIX_ENV=prod mix release).
      {:igniter, "~> 0.8"},
      # ERRC Raise lane 6: property-based testing with shrinking (test-only
      # usage; declared env-prod because `ash` requires stream_data
      # non-optionally — Mix surface-convergence constraint, never packaged:
      # files: whitelist above excludes deps/).
      {:stream_data, "~> 1.2"},
      # Static security analysis (ERRC lane 8 Raise). Non-blocking first pass;
      # recipe `just sobelow` records, does not gate.
      {:sobelow, "~> 0.13", only: :dev, runtime: false},
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
