defmodule Smalt.Integration.GraphlawCanonicalShapesCourtTest do
  @moduledoc false

  # Lane G2 (Wave C) canonical-shapes court: proves the WHOLE canonical
  # ontology (priv/ontologies/public-cloud-2.ttl, including the lane-G2
  # event/ingest section) is metashape-valid on the REAL pinned GraphLaw wasm
  # engine — no :shapes override. This closes the lane-8 bnode lease: the
  # two-sh:pattern defect was already collapsed to a single pattern (lane-9
  # ENGINE-LAW comment, ~line 218); this court makes that standing mechanical.
  #
  # Real collaborators, no stubs: the REAL engine via
  # Smalt.GraphlawEx.ShaclAdmission.admit/2 with NO :shapes override for the
  # baseline tests, so the canonical file on disk is the shapes graph.
  #
  #   1. canonical shapes graph readable + contains the event/ingest section
  #   2. conforming ObjectStorage instance admitted via canonical shapes
  #      (whole-file metashape validity, the former lane-8 lease)
  #   3. conforming AoQ stream frame admitted via prov:StreamFrameShape
  #   4. bad crc32 pattern -> typed refusal with PatternConstraintComponent
  #   5. out-of-vocabulary predicate -> typed refusal whose component is
  #      ClosedConstraintComponent (sh:closed specifically, see below)
  #   6. sh:closed-removal shim court: the same OOV frame ADMITS when
  #      sh:closed is stripped from prov:ShapeFrameShape — proves test 5's
  #      refusal is CARRIED by sh:closed, not vacuously by a shape mismatch.
  #
  # NON-VACUITY LAW for tests 5/6 (L16 cross-court audit finding): the OOV
  # corpus MUST carry the full conforming corpus including
  # `<stream> a cimi:StreamSource` — otherwise the refusal is carried by
  # ClassConstraintComponent on prov:used (missing sh:class type in the data
  # graph) and the sh:closed assertion is tautological. The shim in test 6 is
  # the flip witness: BASELINE refuse -> SHIM (sh:closed stripped from
  # prov:StreamFrameShape via the engine's documented :shapes override; no
  # file is mutated, so restore is byte-true by construction) -> the court
  # flips ADMIT.
  #
  # PRIV-COPY TRAP (L16 audit, for any future FILE-mutating TTL shim):
  # `mix test` resolves :code.priv_dir(:smalt) into the PROFILE build root,
  # and some setups COPY priv/ instead of symlinking it (this checkout's lane
  # roots symlink it: _build-laneG2/{dev,test}/lib/smalt/priv ->
  # ../../../../priv, so TTL edits are live here). Any shim that mutates
  # priv/ontologies/public-cloud-core.ttl MUST first verify the profile's
  # _build priv copy resolves to the same bytes as the source file, or the
  # shim is vacuously inert (baseline still passes, flip never observed,
  # court fake-greens).

  use ExUnit.Case, async: false

  alias Smalt.GraphlawEx.ShaclAdmission

  @manifest_path "/Users/sac/ash_graphlaw/priv/graphlaw/MANIFEST.json"

  @closed_component "http://www.w3.org/ns/shacl#ClosedConstraintComponent"
  @pattern_component "http://www.w3.org/ns/shacl#PatternConstraintComponent"

  # A fully conforming instance of tosca:ObjectStorageShape (canonical shape 2),
  # copied verbatim from the WO-09 court's conforming corpus.
  @conforming_object_storage """
  @prefix tosca: <http://docs.oasis-open.org/tosca/ns/simple/yaml/1.3/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix org: <http://www.w3.org/ns/org#> .
  @prefix sec: <https://w3id.org/security#> .

  <https://smalt.example/obj/1> a tosca:tosca.nodes.Storage.ObjectStorage ;
    dcterms:identifier "obj-1" ;
    org:organizationalUnit "platform" ;
    dcterms:temporal 3650 ;
    sec:digest "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" .
  """

  # A conforming stream source + AoQ frame pair (event/ingest section).
  # Header fields mirror the AoQ1 wire frame: magic AOQ1, version u16, epoch
  # u16, seq u64, type u8, flags u16, payload_len u64, crc32 8-hex.
  @conforming_frame """
  @prefix prov: <http://www.w3.org/ns/prov#> .
  @prefix cimi: <http://schemas.dmtf.org/cimi/2/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

  <https://smalt.example/stream/eh-1> a cimi:StreamSource ;
    dcterms:identifier "eh-schema-42" ;
    dcterms:title "ingest.events" .

  <https://smalt.example/frame/1> a prov:Activity ;
    dcterms:identifier "1:0" ;
    cimi:frame.magic "AOQ1" ;
    cimi:frame.version 1 ;
    cimi:frame.epoch 1 ;
    cimi:frame.sequence 0 ;
    cimi:frame.type 3 ;
    cimi:frame.flags 0 ;
    cimi:frame.payloadLength 128 ;
    cimi:frame.crc32 "DEADBEEF" ;
    prov:startedAtTime "2026-11-04T00:00:00Z"^^xsd:dateTime ;
    prov:used <https://smalt.example/stream/eh-1> .
  """

  # Pattern-violation corpus: full conforming corpus except crc32 is not 8-hex.
  @bad_crc_frame """
  @prefix prov: <http://www.w3.org/ns/prov#> .
  @prefix cimi: <http://schemas.dmtf.org/cimi/2/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

  <https://smalt.example/stream/eh-1> a cimi:StreamSource ;
    dcterms:identifier "eh-schema-42" ;
    dcterms:title "ingest.events" .

  <https://smalt.example/frame/2> a prov:Activity ;
    dcterms:identifier "1:1" ;
    cimi:frame.magic "AOQ1" ;
    cimi:frame.version 1 ;
    cimi:frame.epoch 1 ;
    cimi:frame.sequence 1 ;
    cimi:frame.type 3 ;
    cimi:frame.flags 0 ;
    cimi:frame.payloadLength 128 ;
    cimi:frame.crc32 "NOT-HEX!" ;
    prov:startedAtTime "2026-11-04T00:00:00Z"^^xsd:dateTime ;
    prov:used <https://smalt.example/stream/eh-1> .
  """

  # Closed-violation corpus (L16 audit fix): the FULL conforming corpus
  # (stream source typed, frame header complete) PLUS exactly one
  # out-of-vocabulary predicate. This is the honest test of sh:closed: every
  # other constraint in prov:StreamFrameShape would pass, so the only lawful
  # refusal carrier is ClosedConstraintComponent.
  @oov_frame """
  @prefix prov: <http://www.w3.org/ns/prov#> .
  @prefix cimi: <http://schemas.dmtf.org/cimi/2/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
  @prefix ex: <https://e/> .

  <https://smalt.example/stream/eh-1> a cimi:StreamSource ;
    dcterms:identifier "eh-schema-42" ;
    dcterms:title "ingest.events" .

  <https://smalt.example/frame/3> a prov:Activity ;
    dcterms:identifier "1:2" ;
    cimi:frame.magic "AOQ1" ;
    cimi:frame.version 1 ;
    cimi:frame.epoch 1 ;
    cimi:frame.sequence 2 ;
    cimi:frame.type 3 ;
    cimi:frame.flags 0 ;
    cimi:frame.payloadLength 128 ;
    cimi:frame.crc32 "DEADBEEF" ;
    prov:startedAtTime "2026-11-04T00:00:00Z"^^xsd:dateTime ;
    prov:used <https://smalt.example/stream/eh-1> ;
    ex:unmodeled 42 .
  """

  setup ctx do
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

  test "canonical shapes graph is readable and carries the event/ingest section" do
    assert {:ok, ttl} = ShaclAdmission.shapes_graph()
    assert ttl =~ "prov:StreamFrameShape"
    assert ttl =~ "cimi:StreamSourceShape"
    assert ttl =~ "cimi:frame.magic"
  end

  test "whole canonical shapes graph metashape-validates: object-storage instance admitted WITHOUT override", %{
    engine_opts: engine_opts
  } do
    # No :shapes override — the canonical file on disk is the shapes graph.
    # This is the mechanical close of the lane-8 two-sh:pattern bnode lease.
    assert {:ok, receipt} = ShaclAdmission.admit(@conforming_object_storage, engine_opts: engine_opts)
    assert receipt.admitted
    assert receipt.engine_digest == ShaclAdmission.pinned_digest()
  end

  test "conforming AoQ stream frame admitted via canonical shapes", %{engine_opts: engine_opts} do
    assert {:ok, receipt} = ShaclAdmission.admit(@conforming_frame, engine_opts: engine_opts)
    assert receipt.admitted
  end

  test "bad crc32 pattern refuses with PatternConstraintComponent", %{engine_opts: engine_opts} do
    assert {:refused, :smalt_shacl_violation, %{results: results}} =
             ShaclAdmission.admit(@bad_crc_frame, engine_opts: engine_opts)

    assert is_list(results) and results != []

    components = Enum.map(results, &Map.get(&1, "component"))
    assert "<#{@pattern_component}>" in components,
           "expected PatternConstraintComponent in #{inspect(components)}"
  end

  test "out-of-vocabulary predicate refuses with ClosedConstraintComponent", %{engine_opts: engine_opts} do
    assert {:refused, :smalt_shacl_violation, %{results: results}} =
             ShaclAdmission.admit(@oov_frame, engine_opts: engine_opts)

    assert is_list(results) and results != []

    components = Enum.map(results, &Map.get(&1, "component"))
    assert "<#{@closed_component}>" in components,
           "expected ClosedConstraintComponent in #{inspect(components)}"

    # The OOV corpus is the full conforming corpus + one predicate: the ONLY
    # lawful violation is the closed one on ex:unmodeled.
    assert components == ["<#{@closed_component}>"],
           "unexpected extra violations: #{inspect(results)}"
  end

  # sh:closed-removal shim court (non-vacuity for the test above). The shim
  # strips sh:closed from prov:StreamFrameShape via the engine's documented
  # :shapes override — no file is mutated, so the restore is byte-true by
  # construction. The flip IS the proof: without sh:closed, the identical
  # frame corpus ADMITS.
  @stream_frame_shape_header """
  prov:StreamFrameShape
      a sh:NodeShape ;
      sh:targetClass prov:Activity ;
      sh:closed true ;
  """
  @stream_frame_shape_shimmed """
  prov:StreamFrameShape
      a sh:NodeShape ;
      sh:targetClass prov:Activity ;
  """

  test "shim court: stripping sh:closed from StreamFrameShape flips the OOV frame to ADMIT", %{
    engine_opts: engine_opts
  } do
    {:ok, ttl} = ShaclAdmission.shapes_graph()

    # SHIM guard: the baseline must contain the exact header we shim.
    assert ttl =~ @stream_frame_shape_header,
           "canonical TTL no longer carries the expected StreamFrameShape header — shim is inert, fix the corpus"

    shimmed = String.replace(ttl, @stream_frame_shape_header, @stream_frame_shape_shimmed)
    refute shimmed == ttl, "shim replaced nothing — vacuous"

    # Baseline (canonical shapes): refused on ClosedConstraintComponent.
    assert {:refused, :smalt_shacl_violation, _} = ShaclAdmission.admit(@oov_frame, engine_opts: engine_opts)

    # SHIM (sh:closed stripped): the SAME corpus admits — the refusal above
    # was carried by sh:closed, not by any other constraint.
    assert {:ok, receipt} = ShaclAdmission.admit(@oov_frame, engine_opts: engine_opts, shapes: shimmed)
    assert receipt.admitted
  end
end
