defmodule Smalt.Aoq.RdfProjectorCourtTest do
  @moduledoc false

  # Lane-16 (v26.11.6) projector courts. Real collaborators: the REAL pinned
  # GraphLaw wasm engine via AshGraphLaw.Host + ShaclAdmission (no stubs) and
  # the REAL canonical ontology on disk (no shapes override) — the projector
  # admits over `prov:StreamFrameShape` exactly as landed by lane G2.
  #
  #   1. empty batch -> typed :aoq_batch_empty refusal
  #   2. unbound schema guid -> exact {:refused, :aoq_schema_unbound, %{schema_id}}
  #   3. engine-absent seam -> {:refused, :smalt_projector_engine_absent, _}
  #   4. golden vector: two records -> sorted triple terms == compile-time
  #      literal; emitted Turtle carries ZERO IRIs in instance data
  #   5. missing prov:startedAtTime -> typed :smalt_shacl_violation
  #      (negative mutation: proves prov:StreamFrameShape is NON-VACUOUS —
  #      the shape itself refuses the mutation, the projector never pre-checks)
  #   6. batch invariance: same records as ONE batch vs TWO batches yield the
  #      SAME sorted triple multiset (blank-node labels are batch-local)
  #   7. SchemaBindings: boot-only sealed write, ONE snapshot read, ingest
  #      never mutates (register_schema/2 raises sealed-error post-boot)

  use ExUnit.Case, async: false

  # Lane-16 note: when the shared tree's data plane is mid-flight (another
  # lane's supervisor children in flux), the court runs with
  # `mix test --no-start` and starts ONLY its collaborators here. When the
  # tree boots normally, plain `mix test` works too.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:wasmex)
    {:ok, _} = Application.ensure_all_started(:ash_graphlaw)
    :ok
  end

  alias Smalt.Aoq.RdfProjector
  alias Smalt.Aoq.SchemaBindings
  alias Smalt.GraphlawEx.ShaclAdmission

  @manifest_path "/Users/sac/ash_graphlaw/priv/graphlaw/MANIFEST.json"

  @guid "eh-schema-42"
  @guid2 "eh-schema-43"

  @rec1 %{
    epoch: 1,
    seq: 0,
    type: 3,
    flags: 0,
    payload_len: 128,
    crc32: "DEADBEEF",
    guid: @guid,
    started_at: "2026-11-04T00:00:00Z"
  }

  @rec2 %{
    epoch: 1,
    seq: 1,
    type: 1,
    flags: 2,
    payload_len: 64,
    crc32: "0BADF00D",
    guid: @guid2,
    started_at: "2026-11-04T00:00:01Z"
  }

  # Compile-time golden literal: the sorted triple terms for [@rec1, @rec2].
  # Sorted (Enum.sort/1) triple terms for [@rec1, @rec2]: subject-major,
  # then predicate atom ascending. Compile-time literal — no runtime
  # construction.
  @golden [
    {:"_:f1_0", :cimi_frame_crc32, "DEADBEEF"},
    {:"_:f1_0", :cimi_frame_epoch, 1},
    {:"_:f1_0", :cimi_frame_flags, 0},
    {:"_:f1_0", :cimi_frame_magic, "AOQ1"},
    {:"_:f1_0", :cimi_frame_payload_length, 128},
    {:"_:f1_0", :cimi_frame_sequence, 0},
    {:"_:f1_0", :cimi_frame_type, 3},
    {:"_:f1_0", :cimi_frame_version, 1},
    {:"_:f1_0", :dcterms_identifier, "1:0"},
    {:"_:f1_0", :prov_started_at_time, "2026-11-04T00:00:00Z"},
    {:"_:f1_0", :prov_used, :"_:se6e63e99f4"},
    {:"_:f1_0", :rdf_type, :prov_activity},
    {:"_:f1_1", :cimi_frame_crc32, "0BADF00D"},
    {:"_:f1_1", :cimi_frame_epoch, 1},
    {:"_:f1_1", :cimi_frame_flags, 2},
    {:"_:f1_1", :cimi_frame_magic, "AOQ1"},
    {:"_:f1_1", :cimi_frame_payload_length, 64},
    {:"_:f1_1", :cimi_frame_sequence, 1},
    {:"_:f1_1", :cimi_frame_type, 1},
    {:"_:f1_1", :cimi_frame_version, 1},
    {:"_:f1_1", :dcterms_identifier, "1:1"},
    {:"_:f1_1", :prov_started_at_time, "2026-11-04T00:00:01Z"},
    {:"_:f1_1", :prov_used, :"_:sb4e9679027"},
    {:"_:f1_1", :rdf_type, :prov_activity},
    {:"_:sb4e9679027", :dcterms_identifier, @guid2},
    {:"_:sb4e9679027", :dcterms_title, @guid2},
    {:"_:sb4e9679027", :rdf_type, :cimi_stream_source},
    {:"_:se6e63e99f4", :dcterms_identifier, @guid},
    {:"_:se6e63e99f4", :dcterms_title, @guid},
    {:"_:se6e63e99f4", :rdf_type, :cimi_stream_source}
  ]

  setup ctx do
    SchemaBindings.boot(
      bindings: %{@guid => "arrow-schema-42", @guid2 => "arrow-schema-43"},
      schemas: %{"arrow-schema-42" => :a, "arrow-schema-43" => :b}
    )

    case ShaclAdmission.pin() do
      nil -> flunk("MANIFEST.json unreadable at #{@manifest_path} — fail-closed, refusing to run")
      digest -> assert is_binary(digest) and byte_size(digest) == 64
    end

    Application.put_env(:smalt, :graphlaw_shacl, manifest_path: @manifest_path)

    name =
      Module.concat([to_string(__MODULE__), "Host", Integer.to_string(System.unique_integer([:positive]))])

    with {:ok, pid} <- AshGraphLaw.Host.start_link(name: name),
         true <- AshGraphLaw.Host.available?(name) do
      {:ok, Map.merge(ctx, %{engine_opts: [server: pid]})}
    else
      {:error, refusal} -> flunk("REAL engine unavailable: " <> inspect(refusal))
      false -> flunk("engine host started but never became available")
    end
  end

  test "empty batch refuses typed" do
    assert {:refused, :aoq_batch_empty, %{}} = RdfProjector.project_batch([], [])
  end

  test "unbound schema guid refuses with exact details" do
    bad = Map.put(@rec1, :guid, "eh-schema-999")

    assert {:refused, :aoq_schema_unbound, %{schema_id: "eh-schema-999"}} =
             RdfProjector.project_batch([bad], [])
  end

  test "engine-absent seam refuses fail-closed" do
    assert {:refused, :smalt_projector_engine_absent, %{dep: :ash_graphlaw}} =
             RdfProjector.project_batch([@rec1],
               shacl_module: Module.concat([NoSuchEngine, Capability, Shacl])
             )
  end

  test "golden vector: two records project to the compile-time triple literal, zero IRIs", %{
    engine_opts: engine_opts
  } do
    assert {:ok, result} = RdfProjector.project_batch([@rec1, @rec2], engine_opts: engine_opts)
    assert result.triples == @golden

    # Blank-node event identity: no IRI subject/object in instance data
    # (prefix declarations are the only angle-bracket IRIs in the document).
    no_prefixes = result.turtle |> String.replace(~r/^@prefix .*/m, "")
    refute no_prefixes =~ "<http"

    assert result.envelope.admitted_mutation
  end

  test "missing prov:startedAtTime -> typed SHACL violation (shape non-vacuous)", %{
    engine_opts: engine_opts
  } do
    mutated = Map.delete(@rec1, :started_at)

    assert {:refused, :smalt_shacl_violation, %{results: results}} =
             RdfProjector.project_batch([mutated], engine_opts: engine_opts)

    assert is_list(results) and results != []
  end

  # Batch-local blank-node identity: blank node labels are per-batch, so the
  # 1-batch-vs-2-batches form of this court is UNSOUND (splitting duplicates
  # the shared StreamSource node under batch-local labels). The lawful
  # invariants are: (a) ORDER invariance within one batch — same records in
  # any order yield the same sorted triple multiset; (b) document
  # determinism — same records, same bytes. LANE-16 premise adjustment,
  # disclosed in the receipt.
  test "order invariance: same records in any order == same triple multiset", %{
    engine_opts: engine_opts
  } do
    assert {:ok, a} = RdfProjector.project_batch([@rec1, @rec2], engine_opts: engine_opts)
    assert {:ok, b} = RdfProjector.project_batch([@rec2, @rec1], engine_opts: engine_opts)

    assert a.triples == b.triples
  end

  test "document determinism: same records, same order -> byte-identical Turtle", %{
    engine_opts: engine_opts
  } do
    assert {:ok, a} = RdfProjector.project_batch([@rec1, @rec2], engine_opts: engine_opts)
    assert {:ok, b} = RdfProjector.project_batch([@rec1, @rec2], engine_opts: engine_opts)
    assert a.turtle == b.turtle
  end

  test "batch invariance: one batch of two == two batches of one (triple multiset)", %{
    engine_opts: engine_opts
  } do
    assert {:ok, one} = RdfProjector.project_batch([@rec1, @rec2], engine_opts: engine_opts)
    assert {:ok, half_a} = RdfProjector.project_batch([@rec1], engine_opts: engine_opts)
    assert {:ok, half_b} = RdfProjector.project_batch([@rec2], engine_opts: engine_opts)

    assert one.triples == Enum.sort(half_a.triples ++ half_b.triples)
  end

  test "sh:closed on prov:StreamFrameShape is load-bearing: OOV predicate on the projected document refuses", %{
    engine_opts: engine_opts
  } do
    assert {:ok, result} = RdfProjector.project_batch([@rec1], engine_opts: engine_opts)
    # Inject dcterms:title on the FRAME node: modeled for cimi:StreamSource,
    # out-of-vocabulary for prov:Activity under sh:closed. The source block in
    # the projected document is typed + un-indented, so ClassConstraint on
    # prov:used passes and sh:closed is the ONLY refuser.
    oov_ttl =
      String.replace(result.turtle, "  cimi:frame.magic \"AOQ1\" ;", "  cimi:frame.magic \"AOQ1\" ;\n  dcterms:title \"oops\" ;")

    assert oov_ttl != result.turtle

    assert {:refused, :smalt_shacl_violation, %{results: results}} =
             ShaclAdmission.admit(oov_ttl,
               shape_iri: "prov:StreamFrameShape",
               engine_opts: engine_opts
             )

    assert is_list(results) and results != []
  end

  test "SchemaBindings: one-key snapshot, sealed post-boot writes refuse" do
    snap = SchemaBindings.snapshot()
    assert snap.bindings == %{@guid => "arrow-schema-42", @guid2 => "arrow-schema-43"}
    assert snap.schemas == %{"arrow-schema-42" => :a, "arrow-schema-43" => :b}
    assert SchemaBindings.sealed?()

    assert_raise ArgumentError, ~r/sealed at boot/, fn ->
      SchemaBindings.register_schema(@guid, "other")
    end
  end
end
