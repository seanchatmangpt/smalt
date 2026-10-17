defmodule Mix.Tasks.Smalt.Gen do
  @shortdoc "Regenerate every projected artifact from the smalt-substrate-pack ontology"

  @moduledoc """
  Regenerates all five projected artifacts from
  `../ggen-marketplace/packs/smalt-substrate-pack` (W1a/W1b/W2a).

  Why a task and not the old alias chain: an alias invoking
  `ggen_igniter.sync` more than once only executes the FIRST stanza —
  `Mix.Task.run/2` skips a task already executed in the current VM, so
  the store_tables/config/cascade/event_registry stanzas silently
  skipped (witnessed 2026-10-17, W2a: `mix smalt.gen` after an ontology
  strategy reclassification left `lib/smalt/store_tables.ex` stale).
  `Mix.Task.rerun/2` forces each stanza.

  After each render the artifact is `mix format`ed (replay identity is
  fenced against the canonical-formatted form by the per-artifact
  replay-identity tests).
  """

  use Mix.Task

  @pack "../ggen-marketplace/packs/smalt-substrate-pack"

  @impl Mix.Task
  def run(_argv) do
    stanzas = [
      {Smalt.Registry,
       "--query control_plane=#{@pack}/queries/control_plane.rq " <>
         "--query payload_rules=#{@pack}/queries/payload_rules.rq " <>
         "--template #{@pack}/templates/registry.ex.eex", "lib/smalt/registry.ex"},
      {Smalt.Ocel.EventRegistry,
       "--query event_types=#{@pack}/queries/event_types.rq " <>
         "--query object_types=#{@pack}/queries/ocel_object_types.rq " <>
         "--template #{@pack}/templates/event_registry.ex.eex",
       "lib/smalt/ocel/event_registry.ex"},
      {Smalt.StoreTables,
       "--query store_tables=#{@pack}/queries/store_tables.rq " <>
         "--template #{@pack}/templates/store_tables.ex.eex", "lib/smalt/store_tables.ex"},
      {Smalt.CascadeEdges,
       "--query cascade_edges=#{@pack}/queries/cascade_edges.rq " <>
         "--template #{@pack}/templates/cascade_edges.ex.eex", "lib/smalt/cascade_edges.ex"},
      {Smalt.Config,
       "--query config_keys=#{@pack}/queries/config_keys.rq " <>
         "--template #{@pack}/templates/config.ex.eex", "lib/smalt/config.ex"}
    ]

    common = "--pack-dir #{@pack} --ontology #{@pack}/ontology.ttl"

    Enum.each(stanzas, fn {module, args, out} ->
      Mix.Task.rerun("ggen_igniter.sync", String.split(common <> " " <> args <> " --out " <> out))

      # The generated file is consumed by `module` below only for format
      # drift detection — format unconditionally (canonical form).
      Mix.Task.rerun("format", [out])

      IO.puts(IO.iodata_to_binary(["smalt.gen: ", out, " (", inspect(module), ")"]))
    end)
  end
end
