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
      "smalt.gen": [
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-substrate-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl " <>
          "--query control_plane=../ggen-marketplace/packs/smalt-substrate-pack/queries/control_plane.rq " <>
          "--query payload_rules=../ggen-marketplace/packs/smalt-substrate-pack/queries/payload_rules.rq " <>
          "--template ../ggen-marketplace/packs/smalt-substrate-pack/templates/registry.ex.eex " <>
          "--out lib/smalt/registry.ex",
        # Replay identity: the generated artifact must be canonical-formatted
        # so `mix smalt.gen` replay is byte-identical (fenced by
        # test/smalt_registry_replay_identity_test.exs).
        "format lib/smalt/registry.ex",
        # OCEL event-type vocabulary (lane 431): projected from the same
        # ontology's smalt:OcelEventType rows. spc.drift gates the SPC
        # emitter (Smalt.Spc.Drift); unknown types stay log-and-drop.
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-substrate-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl " <>
          "--query event_types=../ggen-marketplace/packs/smalt-substrate-pack/queries/event_types.rq " <>
          "--query object_types=../ggen-marketplace/packs/smalt-substrate-pack/queries/ocel_object_types.rq " <>
          "--template ../ggen-marketplace/packs/smalt-substrate-pack/templates/event_registry.ex.eex " <>
          "--out lib/smalt/ocel/event_registry.ex",
        "format lib/smalt/ocel/event_registry.ex",
        # W1b Store table registry (recipe step 5): every ETS table atom —
        # owned (Smalt.Store @tables) + shadow (lazily created, sweepStrategy
        # none) — projected from the smalt:StoreTable individuals. The
        # generated registry REPLACES the hand-written lists (store.ex,
        # enclave/state.ex, store/dets_mirror.ex consume it). Fenced by
        # test/store_tables_replay_identity_test.exs.
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-substrate-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl " <>
          "--query store_tables=../ggen-marketplace/packs/smalt-substrate-pack/queries/store_tables.rq " <>
          "--template ../ggen-marketplace/packs/smalt-substrate-pack/templates/store_tables.ex.eex " <>
          "--out lib/smalt/store_tables.ex",
        "format lib/smalt/store_tables.ex",
        # W2a Cascade dispatch table (capture-then-sweep census): one row
        # per smalt:CascadeEdge individual. Projects the DECLARATION +
        # dispatch table only — the owner-module drop functions stay
        # hand-written (residue doctrine). Fenced by
        # test/cascade_replay_identity_test.exs +
        # verify/cascade-coverage.unbound.rq (referential integrity of
        # childTable -> StoreTable + cascade-table coverage).
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-substrate-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl " <>
          "--query cascade_edges=../ggen-marketplace/packs/smalt-substrate-pack/queries/cascade_edges.rq " <>
          "--template ../ggen-marketplace/packs/smalt-substrate-pack/templates/cascade_edges.ex.eex " <>
          "--out lib/smalt/cascade_edges.ex",
        "format lib/smalt/cascade_edges.ex",
        # W1a: ConfigKey census -> Smalt.Config accessors. One zero-arity
        # accessor per smalt:ConfigKey row; the ontology default is the
        # ONLY copy of the in-code default. Replay-identity fence:
        # test/config_replay_identity_test.exs.
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-substrate-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl " <>
          "--query config_keys=../ggen-marketplace/packs/smalt-substrate-pack/queries/config_keys.rq " <>
          "--template ../ggen-marketplace/packs/smalt-substrate-pack/templates/config.ex.eex " <>
          "--out lib/smalt/config.ex",
        "format lib/smalt/config.ex",
        # W2b: semconv registry — true projection replacing the hand-sync
        # (smalt.yaml → registry.ex was hand-rendered with a fence). Source
        # of truth: ggen-marketplace/packs/smalt-semconv-pack/ontology.ttl
        # (smaltv:SemConvEvent / SemConvAttribute / OcelMappingRule rows);
        # the YAML stays as the mirrored human-readable model. Byte-identity
        # is fenced by test/semconv_replay_identity_test.exs; the behavioral
        # gate remains test/semconv_test.exs (YAML↔registry model fence).
        "ggen_igniter.sync --pack-dir ../ggen-marketplace/packs/smalt-semconv-pack " <>
          "--ontology ../ggen-marketplace/packs/smalt-semconv-pack/ontology.ttl " <>
          "--query semconv_events=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_events.rq " <>
          "--query semconv_bindings=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_bindings.rq " <>
          "--query semconv_attributes=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_attributes.rq " <>
          "--query semconv_mapping_rules=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_mapping_rules.rq " <>
          "--template ../ggen-marketplace/packs/smalt-semconv-pack/templates/registry.ex.eex " <>
          "--out lib/smalt/telemetry/semconv/registry.ex",
        "format lib/smalt/telemetry/semconv/registry.ex"
      ],
      # R164: named tiers. cross_seat runs the auth cross-seat suite in
      # isolation (default-excluded tag); amqp_wire includes the wire tier.
      "test.cross_seat": ["test --only cross_seat test/auth_enforce_test.exs"],
      "test.amqp_wire": ["test --include amqp_wire"]
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
    [preferred_envs: ["test.cross_seat": :test, "test.amqp_wire": :test]]
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
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:cors_plug, "~> 3.0"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:ash, "~> 3.33", optional: true},
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
    ] ++
      path_dep(:ash_graphlaw, "../ash_graphlaw", only: :dev) ++
      path_dep(:ash_r2rml, "../ash_r2rml", only: [:dev, :test]) ++
      path_dep(:ash_ex4pm, "../ash_ex4pm", only: [:dev, :test]) ++
      path_dep(:ex4pm, "../ex4pm", override: true) ++
      path_dep(:ggen_igniter, "../ggen_igniter", only: :dev)
  end

  defp path_dep(app, path, opts) do
    if File.dir?(path) do
      [{app, Keyword.merge([path: path, optional: true], opts)}]
    else
      []
    end
  end
end
