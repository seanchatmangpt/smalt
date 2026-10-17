defmodule Mix.Tasks.Smalt.Gen do
  @shortdoc "Regenerate every projected artifact from the pack ontologies"

  @moduledoc """
  Regenerates all six projected artifacts (W1a/W1b/W2a/W2b).

  Why a task and not the old alias chain: an alias invoking
  `ggen_igniter.sync` more than once only executes the FIRST stanza —
  `Mix.Task.run/2` skips a task already executed in the current VM, so
  the store_tables/config/cascade/event_registry/semconv stanzas were
  silently skipped (witnessed 2026-10-17, W2a: `mix smalt.gen` after an
  ontology strategy reclassification left `lib/smalt/store_tables.ex`
  stale). `Mix.Task.rerun/2` forces each stanza.

  After each render the artifact is `mix format`ed (replay identity is
  fenced against the canonical-formatted form by the per-artifact
  replay-identity tests).
  """

  use Mix.Task

  @pack "../ggen-marketplace/packs/smalt-substrate-pack"
  @common "--pack-dir #{@pack} --ontology #{@pack}/ontology.ttl"

  @impl Mix.Task
  def run(_argv) do
    stanzas = [
      {"#{@common} --query control_plane=#{@pack}/queries/control_plane.rq " <>
         "--query payload_rules=#{@pack}/queries/payload_rules.rq " <>
         "--template #{@pack}/templates/registry.ex.eex --out lib/smalt/registry.ex",
       "lib/smalt/registry.ex"},
      {"#{@common} --query event_types=#{@pack}/queries/event_types.rq " <>
         "--query object_types=#{@pack}/queries/ocel_object_types.rq " <>
         "--template #{@pack}/templates/event_registry.ex.eex --out lib/smalt/ocel/event_registry.ex",
       "lib/smalt/ocel/event_registry.ex"},
      {"#{@common} --query store_tables=#{@pack}/queries/store_tables.rq " <>
         "--template #{@pack}/templates/store_tables.ex.eex --out lib/smalt/store_tables.ex",
       "lib/smalt/store_tables.ex"},
      {"#{@common} --query cascade_edges=#{@pack}/queries/cascade_edges.rq " <>
         "--template #{@pack}/templates/cascade_edges.ex.eex --out lib/smalt/cascade_edges.ex",
       "lib/smalt/cascade_edges.ex"},
      {"#{@common} --query config_keys=#{@pack}/queries/config_keys.rq " <>
         "--template #{@pack}/templates/config.ex.eex --out lib/smalt/config.ex",
       "lib/smalt/config.ex"},
      # W2b (cross-lane stanza, disclosed relocation from the alias):
      # semconv registry from its own pack.
      {"--pack-dir ../ggen-marketplace/packs/smalt-semconv-pack " <>
         "--ontology ../ggen-marketplace/packs/smalt-semconv-pack/ontology.ttl " <>
         "--query semconv_events=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_events.rq " <>
         "--query semconv_bindings=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_bindings.rq " <>
         "--query semconv_attributes=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_attributes.rq " <>
         "--query semconv_mapping_rules=../ggen-marketplace/packs/smalt-semconv-pack/queries/semconv_mapping_rules.rq " <>
         "--template ../ggen-marketplace/packs/smalt-semconv-pack/templates/registry.ex.eex " <>
         "--out lib/smalt/telemetry/semconv/registry.ex",
       "lib/smalt/telemetry/semconv/registry.ex"}
    ]

    Enum.each(stanzas, fn {args, out} ->
      Mix.Task.rerun("ggen_igniter.sync", String.split(args))
      Mix.Task.rerun("format", [out])
      IO.puts("smalt.gen: #{out} ok")
    end)
  end
end
