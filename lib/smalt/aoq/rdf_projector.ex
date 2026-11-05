defmodule Smalt.Aoq.RdfProjector do
  @moduledoc false

  # Lane-16 (v26.11.6) AoQ drain-boundary RDF projector.
  #
  # Projects a batch of admitted AoQ frames into ONE Turtle instance
  # document over the LANDED (G2) prov:StreamFrameShape /
  # cimi:StreamSourceShape shapes, then admits the whole batch in ONE
  # ShaclAdmission.admit_envelope/2 call on the REAL pinned GraphLaw
  # wasm engine.
  #
  # NAMESPACE RECONCILIATION (LANE-16 DECISION): G2's PROV-only core
  # graph stands as landed (the zero-proprietary verifier rejects the
  # ocel-standard namespace, so the canonical TTL carries NO OCEL terms).
  # OCEL projection stays confined to the ggen projector side
  # (crates/ggen-graph/src/ocel/projection.rs); this module emits only
  # prov: / cimi: / dcterms: terms.
  #
  # EMISSION LAW: blank-node event identity (`_:fN` frames, `_:sN`
  # sources) — ZERO IRIs in instance data; dotted header terms exactly
  # as landed (cimi:frame.magic "AOQ1", cimi:frame.version,
  # cimi:frame.epoch, cimi:frame.sequence, cimi:frame.type,
  # cimi:frame.flags, cimi:frame.payloadLength, cimi:frame.crc32,
  # dcterms:identifier "epoch:seq", prov:startedAtTime ^^xsd:dateTime,
  # prov:used -> cimi:StreamSource with the guid in dcterms:identifier);
  # iolist-only emission, ONE flatten; ONE persistent_term read (the
  # {:aoq, :schema_bindings} snapshot) and ONE admit_envelope/2 call per
  # batch. Fail-closed refusals: :aoq_batch_empty, :aoq_schema_unbound,
  # :smalt_projector_engine_absent, :aoq_bindings_unbooted, plus
  # pass-through SHACL/engine refusals. A record without :started_at is
  # projected without prov:startedAtTime — the shape's sh:minCount 1
  # refuses it (the shape owns that law; the negative-mutation court
  # surface).

  alias Smalt.Aoq.SchemaBindings
  alias Smalt.GraphlawEx.ShaclAdmission

  @shape_iri "prov:StreamFrameShape"
  @magic "AOQ1"

  @prefixes """
  @prefix prov: <http://www.w3.org/ns/prov#> .
  @prefix cimi: <http://schemas.dmtf.org/cimi/2/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

  """

  @typedoc "One drain-boundary frame record: an admitted frame plus its schema guid."
  @type frame_record :: %{
          required(:epoch) => non_neg_integer(),
          required(:seq) => non_neg_integer(),
          required(:type) => non_neg_integer(),
          required(:flags) => non_neg_integer(),
          required(:payload_len) => pos_integer(),
          required(:crc32) => String.t(),
          required(:guid) => String.t(),
          optional(:started_at) => String.t()
        }

  @typedoc "Success payload: sorted triple terms, flattened Turtle, envelope."
  @type result :: %{
          required(:triples) => [{term(), term(), term()}],
          required(:turtle) => String.t(),
          required(:envelope) => map()
        }

  @doc """
  Project ONE batch of records to Turtle and admit the whole batch in ONE
  envelope.

  Opts: `:engine_opts` — passed to `admit_envelope/2` (the `[server: pid]`
  of a started AshGraphLaw.Host). `:shacl_module` — COURT SEAM ONLY
  (disclosed; production callers omit it): overrides the resolved
  AshGraphLaw.Capability.Shacl module so the engine-absent fail-closed
  refusal is courtable in an env where the dep IS loaded.

  A record without `:started_at` is projected WITHOUT the
  prov:startedAtTime triple — the landed shape's sh:minCount 1 refuses
  the batch (the shape owns that law; the projector never pre-checks).
  """
  @spec project_batch([frame_record()], keyword()) :: {:ok, result()} | {:refused, atom(), map()}
  def project_batch([], _opts), do: {:refused, :aoq_batch_empty, %{}}

  def project_batch(records, opts) when is_list(records) do
    with {:ok, snapshot} <- bindings_snapshot(),
         :ok <- check_bound(records, snapshot),
         :ok <- engine_present?(opts),
         ttl = build_document(records),
         {:ok, envelope} <-
           ShaclAdmission.admit_envelope(ttl,
             shape_iri: @shape_iri,
             engine_opts: opts[:engine_opts] || []
           ) do
      {:ok, %{triples: triples(records), turtle: ttl, envelope: envelope}}
    else
      {:refused, :smalt_graphlaw_engine_absent, details} ->
        {:refused, :smalt_projector_engine_absent, Map.put(details, :stage, :admit_envelope)}

      {:refused, _, _} = refused ->
        refused
    end
  end

  @doc "Sorted triple terms for the given records (golden-vector form)."
  @spec triples([frame_record()]) :: [{term(), term(), term()}]
  def triples(records), do: records |> triples_unsorted() |> Enum.sort()

  # ── internals ────────────────────────────────────────────────────────

  defp bindings_snapshot do
    {:ok, SchemaBindings.snapshot()}
  rescue
    ArgumentError -> {:refused, :aoq_bindings_unbooted, %{}}
  end

  defp check_bound(records, snapshot) do
    case records |> Enum.reject(&is_map_key(snapshot.bindings, &1.guid)) do
      [] -> :ok
      [bad | _] -> {:refused, :aoq_schema_unbound, %{schema_id: bad.guid}}
    end
  end

  defp engine_present?(opts) do
    mod = opts[:shacl_module] || Module.concat([AshGraphLaw, Capability, Shacl])

    if Code.ensure_loaded?(mod) do
      :ok
    else
      {:refused, :smalt_projector_engine_absent, %{dep: :ash_graphlaw, stage: :engine_check}}
    end
  end

  defp build_document(records) do
    records
    |> document_iolist()
    |> IO.iodata_to_binary()
  end

  defp document_iolist(records) do
    [
      @prefixes,
      sources_iolist(records),
      frames_iolist(records)
    ]
  end

  # Content-addressed blank-node identity: a frame's label is a function of
  # its epoch:seq identity, a source's label a function of its guid
  # (sha256-prefix hex). Labels are stable across batches and record order —
  # the projected graph is a pure function of the record CONTENT, which is
  # what the order/identity courts prove.
  defp source_index(records) do
    records
    |> Enum.uniq_by(& &1.guid)
    |> Map.new(fn r -> {r.guid, source_label(r.guid)} end)
  end

  defp source_label(guid) do
    hex = Base.encode16(:crypto.hash(:sha256, guid), case: :lower)
    "_:s" <> binary_part(hex, 0, 10)  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
  end


  defp sources_iolist(records) do
    records
    |> Enum.uniq_by(& &1.guid)
    |> Enum.map(fn rec ->
        label = source_label(rec.guid)

        [
          label,
          " a cimi:StreamSource ;\n  dcterms:identifier \"",
          rec.guid,
          "\" ;\n  dcterms:title \"",
          rec.guid,
          "\" .\n\n"
        ]
      end)
  end

  defp frames_iolist(records) do
    src_ix = source_index(records)
    Enum.map(records, &frame_iolist(&1, src_ix))
  end

  defp frame_label(rec) do
    "_:f" <> Integer.to_string(rec.epoch) <> "_" <> Integer.to_string(rec.seq)  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
  end

  defp frame_iolist(rec, src_ix) do
    src = "  prov:used " <> Map.fetch!(src_ix, rec.guid) <> " .\n\n"  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress

    started =
      case rec[:started_at] do
        nil -> []
        ts -> ["  prov:startedAtTime \"" <> ts <> "\"^^xsd:dateTime ;\n"]  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      end

    [
      frame_label(rec),
      " a prov:Activity ;\n",
      "  dcterms:identifier \"",
      Integer.to_string(rec.epoch),
      ":",
      Integer.to_string(rec.seq),
      "\" ;\n",
      "  cimi:frame.magic \"AOQ1\" ;\n",
      "  cimi:frame.version " <> Integer.to_string(1) <> " ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      "  cimi:frame.epoch " <> Integer.to_string(rec.epoch) <> " ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      "  cimi:frame.sequence " <> Integer.to_string(rec.seq) <> " ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      "  cimi:frame.type " <> Integer.to_string(rec.type) <> " ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      "  cimi:frame.flags " <> Integer.to_string(rec.flags) <> " ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      "  cimi:frame.payloadLength " <> Integer.to_string(rec.payload_len) <> " ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      "  cimi:frame.crc32 \"" <> rec.crc32 <> "\" ;\n",  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
      started,
      src
    ]
  end

  defp triples_unsorted(records) do
    src_ix = source_index(records)

    frame_triples =
      for rec <- records do
        f = String.to_atom(frame_label(rec))
        s = String.to_atom(Map.fetch!(src_ix, rec.guid))

        base = [
          {f, :rdf_type, :prov_activity},
          {f, :dcterms_identifier, Integer.to_string(rec.epoch) <> ":" <> Integer.to_string(rec.seq)},  # AOQ-FENCE-OK: prose/Turtle text build, not AoQ frame egress
          {f, :cimi_frame_magic, @magic},
          {f, :cimi_frame_version, 1},
          {f, :cimi_frame_epoch, rec.epoch},
          {f, :cimi_frame_sequence, rec.seq},
          {f, :cimi_frame_type, rec.type},
          {f, :cimi_frame_flags, rec.flags},
          {f, :cimi_frame_payload_length, rec.payload_len},
          {f, :cimi_frame_crc32, rec.crc32},
          {f, :prov_used, s}
        ]

        case rec[:started_at] do
          nil -> base
          ts -> base ++ [{f, :prov_started_at_time, ts}]
        end
      end

    source_triples =
      for {guid, label} <- src_ix,
          atom = String.to_atom(label),
          t <- [
            {atom, :rdf_type, :cimi_stream_source},
            {atom, :dcterms_identifier, guid},
            {atom, :dcterms_title, guid}
          ] do
        t
      end

    Enum.flat_map(frame_triples, & &1) ++ source_triples
  end
end
