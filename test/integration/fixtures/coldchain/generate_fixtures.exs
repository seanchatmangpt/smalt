# COLD-1 fixture generator — deterministic OCEL v2 CSV corpus + RDF SQL AST TTL.
# Run: MIX_BUILD_ROOT=_build-cold1 mix run test/integration/fixtures/coldchain/generate_fixtures.exs
# Deterministic: fixed literal dataset, no RNG — byte-identical on rerun (replayable court).

defmodule ColdchainFixtures do
  @moduledoc false

  @out_dir Path.join(["tmp", "coldchain"])
  @ast_path Path.join(["test", "integration", "fixtures", "coldchain", "cold_chain_ast.ttl"])

  @literals %{t_excursion: -20.0, t_release: -15.0, d_max: 300}

  # 10 batches: 3 quarantine-class (Q), 5 release-class (R), 2 ambiguous (A).
  # Each batch: list of {temp_celsius, duration_seconds, qualifier}.
  @batches %{
    # --- quarantine-class ---
    "BATCH-Q1" => [{-12.5, 400, "contains_product"}, {-18.0, 50, "sensor_heartbeat"}],
    "BATCH-Q2" => [{-14.0, 100, "contains_product"}, {-19.9, 40, "contains_product"}],
    "BATCH-Q3" => [{-17.0, 200, "contains_product"}, {-16.0, 200, "contains_product"}],
    # --- release-class ---
    # NOTE: release-class batches MUST have qualifying exposure events
    # (-20.0 < temp < -15.0, cumulative duration <= 300) or the `temp > -20.0`
    # pushdown eliminates the batch entirely and the pipeline fail-closes it.
    "BATCH-R1" => [{-17.0, 120, "contains_product"}],
    "BATCH-R2" => [{-19.0, 150, "contains_product"}, {-18.5, 100, "contains_product"}],
    "BATCH-R3" => [{-16.0, 300, "contains_product"}],
    "BATCH-R4" => [{-16.5, 250, "contains_product"}, {-20.0, 400, "sensor_heartbeat"}],
    "BATCH-R5" => [{-19.5, 100, "contains_product"}, {-19.9, 100, "contains_product"}],
    # --- ambiguous (edge literals; naive readings flip, fail-closed must not) ---
    # max == -15.0 exactly AND duration == 300 exactly: `max >= -15` ⇒ quarantine.
    "BATCH-A1" => [{-15.0, 300, "contains_product"}],
    # every event at exactly -20.0 ⇒ excluded by strict `temp > -20.0` ⇒ NO aggregate
    # row ⇒ missing premise ⇒ fail-closed quarantine (never release).
    "BATCH-A2" => [{-20.0, 600, "contains_product"}, {-20.0, 100, "contains_product"}]
  }

  def run! do
    File.mkdir_p!(@out_dir)
    %{rows: ev_rows, rel_rows: rel_rows, objects: objects} = build_events()

    write_csv("ocel_events.csv", ~w(event_id event_type timestamp temp_celsius duration_seconds), ev_rows)
    write_csv("ocel_event_object_rel.csv", ~w(event_id object_id qualifier), rel_rows)
    write_csv("ocel_objects.csv", ~w(object_id object_type lot_number), objects)
    File.write!(@ast_path, render_ast())

    %{
      out_dir: @out_dir,
      ast_path: @ast_path,
      batch_ids: Map.keys(@batches),
      literals: @literals
    }
  end

  def batches, do: @batches
  def literals, do: @literals
  def out_dir, do: @out_dir
  def ast_path, do: @ast_path

  defp build_events do
    {ev_rows, rel_rows, objects} =
      Enum.reduce(@batches, {[], [], []}, fn {batch, evs}, {r, rr, objs} ->
        objs = objs ++ [[batch, "bio:BiologicBatch", "LOT-" <> String.trim_leading(batch, "BATCH-")]]

        {ev, rel} =
          evs
          |> Enum.with_index(1)
          |> Enum.map(fn {{t, d, q}, i} ->
            eid = "EVT-#{batch}-#{i}"

            {
              [eid, "bio:ColdChainLog", "2026-10-21T00:00:00Z", fmt(t), Integer.to_string(d)],
              [eid, batch, q]
            }
          end)
          |> Enum.unzip()

        {r ++ ev, rr ++ rel, objs}
      end)

    %{rows: ev_rows, rel_rows: rel_rows, objects: objects}
  end

  defp fmt(t), do: :erlang.float_to_binary(t * 1.0, decimals: 1)

  defp write_csv(name, header, rows) do
    path = Path.join(@out_dir, name)

    body =
      [header | rows]
      |> Enum.map_join("\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)

    File.write!(path, body <> "\n")
    path
  end

  defp csv_cell(v) when is_binary(v), do: v
  defp csv_cell(v), do: to_string(v)

  defp render_ast do
    """
    # RDF AST fixture — hand-compiled documentation artifact for the COLD-1 court.
    # Compilation provenance: COLDCHAIN-CASE-STUDY.md sec 3 (ex:ColdChainExcursionQuery).
    @prefix ex: <http://example.org/> .
    @prefix sql: <http://example.org/sql#> .
    @prefix bio: <http://example.org/bio#> .

    ex:ColdChainExcursionQuery a sql:SelectStatement ;
      sql:tables [ a sql:Join ;
        sql:left [ a sql:Join ;
          sql:left [ a sql:Table ; sql:name "ocel_events" ; sql:alias "e" ] ;
          sql:right [ a sql:Table ; sql:name "ocel_event_object_rel" ; sql:alias "r" ] ;
          sql:on "e.event_id = r.event_id" ] ;
        sql:right [ a sql:Table ; sql:name "ocel_objects" ; sql:alias "o" ] ;
        sql:on "r.object_id = o.object_id" ] ;
      sql:whereClause [ a sql:And ;
        sql:left [ a sql:Compare ; sql:op ">" ; sql:operand "e.temp_celsius" ; sql:literal -20.0 ] ;
        sql:right [ a sql:And ;
          sql:left [ a sql:Compare ; sql:op "=" ; sql:operand "r.qualifier" ; sql:literal "contains_product" ] ;
          sql:right [ a sql:Compare ; sql:op "=" ; sql:operand "o.object_type" ; sql:literal "bio:BiologicBatch" ] ] ] ;
      sql:groupBy [ a sql:Var ; sql:name "o.object_id" ] ;
      sql:select [ a sql:Max ; sql:operand "e.temp_celsius" ; sql:as "max_temp" ] ,
                  [ a sql:Sum ; sql:operand "e.duration_seconds" ; sql:as "duration" ] .
    """
  end
end

ColdchainFixtures.run!()
