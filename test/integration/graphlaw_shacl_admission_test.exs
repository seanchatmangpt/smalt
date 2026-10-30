defmodule Smalt.Integration.GraphlawShaclAdmissionTest do
  @moduledoc false

  # WO-09 (v26.10.31, lane 9): the SHACL admission gate end to end.
  #
  # Real collaborators, no stubs: the REAL pinned GraphLaw wasm engine
  # (MANIFEST artifact.sha256 34fd4ada...), a REAL AshGraphLaw.Host supervising
  # it, the canonical ontology priv/ontologies/public-cloud-core.ttl as the
  # shapes graph, and the host-side AdmissionGate on top.
  #
  #   1. conforming instance => admit + receipt, envelope passes gate
  #   2. mutated property (sh:closed OOV predicate) => :smalt_shacl_violation
  #   3. digest-pin tamper court => :smalt_engine_drift (proves pin runs)
  #
  # An unusable engine flunks loudly, never silently passes.

  use ExUnit.Case, async: false

  alias Smalt.GraphlawEx.AdmissionGate
  alias Smalt.GraphlawEx.ShaclAdmission

  @manifest_path "/Users/sac/ash_graphlaw/priv/graphlaw/MANIFEST.json"

  # WO-09 BLOCKED-adjacent note (loud, not a skip): the in-flight canonical
  # ontology currently carries a bnode with TWO sh:pattern values
  # (~lines 217-218, lane 8's lease), which the REAL engine refuses at
  # shapes-graph meta-validation — the full public-cloud-core.ttl is
  # engine-rejected wholesale today. Until lane 8's fix lands, this court
  # exercises the canonical shape #2 (tosca:ObjectStorageShape, copied
  # VERBATIM from the canonical file) via the documented :shapes override.
  # When the ontology goes metashape-valid the override can be dropped and
  # every court call re-pointed at ShaclAdmission.shapes_graph().
  @object_storage_shapes """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix tosca: <http://docs.oasis-open.org/tosca/ns/simple/yaml/1.3/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix org: <http://www.w3.org/ns/org#> .
  @prefix sec: <https://w3id.org/security#> .
  @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

  tosca:ObjectStorageShape a sh:NodeShape ;
    sh:targetClass tosca:tosca.nodes.Storage.ObjectStorage ;
    sh:closed true ;
    sh:ignoredProperties ( rdf:type ) ;
    sh:property [ sh:path dcterms:identifier ; sh:datatype xsd:string ; sh:minCount 1 ; sh:maxCount 1 ] ;
    sh:property [ sh:path org:organizationalUnit ; sh:datatype xsd:string ; sh:minCount 1 ; sh:maxCount 1 ] ;
    sh:property [ sh:path dcterms:temporal ; sh:datatype xsd:integer ; sh:minCount 1 ; sh:maxCount 1 ; sh:minInclusive 1 ; sh:maxInclusive 3650 ] ;
    sh:property [ sh:path sec:digest ; sh:datatype xsd:string ; sh:minCount 1 ; sh:maxCount 1 ; sh:minLength 64 ; sh:maxLength 64 ] .
  """

  # A fully conforming instance of tosca:ObjectStorageShape
  # (public-cloud-core.ttl shape #2): identifier, org unit, temporal 1..3650,
  # 64-hex digest, node typed tosca:tosca.nodes.Storage.ObjectStorage.
  @conforming """
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

  # Same subject, one out-of-vocabulary predicate added (sh:closed violation;
  # rdf:type remains ignored per sh:ignoredProperties).
  @mutated """
  @prefix tosca: <http://docs.oasis-open.org/tosca/ns/simple/yaml/1.3/> .
  @prefix dcterms: <http://purl.org/dc/terms/> .
  @prefix org: <http://www.w3.org/ns/org#> .
  @prefix sec: <https://w3id.org/security#> .
  @prefix ex: <https://e/> .

  <https://smalt.example/obj/1> a tosca:tosca.nodes.Storage.ObjectStorage ;
    dcterms:identifier "obj-1" ;
    org:organizationalUnit "platform" ;
    dcterms:temporal 3650 ;
    sec:digest "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ;
    ex:unmodeled 42 .
  """

  setup ctx do
    # Pin :gl_engine_digest from the canonical MANIFEST.json before anything
    # observes it.
    case ShaclAdmission.pin() do
      nil -> flunk("MANIFEST.json unreadable at #{@manifest_path} — fail-closed, refusing to run")
      digest -> assert is_binary(digest) and byte_size(digest) == 64
    end

    Application.put_env(:smalt, :graphlaw_shacl, manifest_path: @manifest_path)

    name = Module.concat([to_string(__MODULE__), "Host", Integer.to_string(System.unique_integer([:positive]))])

    with {:ok, pid} <- AshGraphLaw.Host.start_link(name: name),
         true <- AshGraphLaw.Host.available?(name) do
      {:ok, Map.merge(ctx, %{engine_opts: [server: pid], host_name: name})}
    else
      {:error, refusal} -> flunk("REAL engine unavailable: " <> inspect(refusal))
      false -> flunk("engine host started but never became available")
    end
  end

  test "conforming instance: admit + receipt + envelope passes AdmissionGate", %{engine_opts: opts} do
    assert {:ok, receipt} = ShaclAdmission.admit(@conforming, opts ++ [shapes: @object_storage_shapes, shape_iri: "tosca:ObjectStorageShape"])
    assert receipt.admitted
    assert receipt.engine_digest == ShaclAdmission.pinned_digest()
    assert byte_size(receipt.receipt_sha256) == 64
    assert Regex.match?(~r/^[0-9a-f]{64}$/, receipt.receipt_sha256)

    assert {:ok, envelope} = ShaclAdmission.admit_envelope(@conforming, opts ++ [shapes: @object_storage_shapes])

    assert :ok ==
             AdmissionGate.gate("PUT", envelope,
               engine_digest: envelope.engine_digest,
               body: envelope.payload_bytes
             )
  end

  test "mutated property: typed refusal citing the sh:closed violation", %{engine_opts: opts} do
    assert {:refused, :smalt_shacl_violation, %{results: results}} =
             ShaclAdmission.admit(@mutated, opts ++ [shapes: @object_storage_shapes])

    assert is_list(results) and results != []

    # And no envelope: a refusal never mints a commit envelope.
    assert {:refused, :smalt_shacl_violation, _} = ShaclAdmission.admit_envelope(@mutated, opts ++ [shapes: @object_storage_shapes])
  end

  test "digest-pin tamper court: tampered envelope refused :smalt_engine_drift", %{engine_opts: opts} do
    assert {:ok, envelope} = ShaclAdmission.admit_envelope(@conforming, opts ++ [shapes: @object_storage_shapes])

    tampered = %{envelope | engine_digest: String.duplicate("ff", 32)}

    assert {:refused, :smalt_engine_drift, details} =
             AdmissionGate.gate("PUT", tampered,
               engine_digest: ShaclAdmission.pinned_digest(),
               body: tampered.payload_bytes
             )

    assert details.expected == ShaclAdmission.pinned_digest()
    assert details.actual == String.duplicate("ff", 32)
  end

  test "unpinned digest refuses fail-closed", %{engine_opts: opts} do
    # Simulate an unpinned node: bypass the persistent_term by passing an
    # explicit nil-equivalent — admit/2 with no pinned digest and no override.
    saved = :persistent_term.get(:gl_engine_digest, nil)
    :persistent_term.erase(:gl_engine_digest)

    try do
      assert {:refused, :smalt_graphlaw_engine_unpinned, _} = ShaclAdmission.admit(@conforming, opts ++ [shapes: @object_storage_shapes])
    after
      :persistent_term.put(:gl_engine_digest, saved)
    end
  end
end
