# WO-08 engine-level court (lane 8 follow-up): the FULL canonical ontology
# as the shapes graph through the REAL graphlaw engine (lane-9 host API),
# proving the sh:pattern meta-validation refusal is gone.
#
# Run: cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-lane8 mix run \
#        priv/ontologies/fixtures/engine_admission_probe.exs
# Exit 0 = engine accepts the whole shapes graph + admits a conforming
# instance and refuses a mutated one; 1 = any leg fails.

shacl = Smalt.GraphlawEx.ShaclAdmission

Application.put_env(:smalt, :graphlaw_shacl,
  manifest_path: "/Users/sac/ash_graphlaw/priv/graphlaw/MANIFEST.json")

shapes = File.read!("priv/ontologies/public-cloud-core.ttl")
ttl = """
@prefix tosca: <http://docs.oasis-open.org/tosca/ns/simple/yaml/1.3/> .
@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix org: <http://www.w3.org/ns/org#> .
@prefix sec: <https://w3id.org/security#> .

<https://smalt.example/rg/1> a org:OrganizationalUnit ;
  dcterms:identifier "/subscriptions/abc/resourceGroups/rg-1" ;
  dcterms:title "rg-1" ;
  dcterms:spatial "eastus" .
"""

mutated = """
@prefix tosca: <http://docs.oasis-open.org/tosca/ns/simple/yaml/1.3/> .
@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix org: <http://www.w3.org/ns/org#> .
@prefix sec: <https://w3id.org/security#> .
@prefix ex: <https://e/> .

<https://smalt.example/rg/1> a org:OrganizationalUnit ;
  dcterms:identifier "/subscriptions/abc/resourceGroups/rg-1" ;
  dcterms:title "rg-1" ;
  dcterms:spatial "eastus" ;
  ex:unmodeled 42 .
"""

case shacl.pin() do
  nil -> IO.puts("[FAIL] engine digest pin unreadable"); System.halt(1)
  d -> IO.puts("[PASS] pinned engine digest #{String.slice(d, 0, 12)}...")
end

name = Module.concat(["EngineProbeHost", Integer.to_string(System.unique_integer([:positive]))])

with {:ok, pid} <- AshGraphLaw.Host.start_link(name: name),
     true <- AshGraphLaw.Host.available?(name) do
  opts = [server: pid]

  # Leg 1: full canonical ttl accepted as shapes graph, no meta-validation
  # error — conforming instance admitted against shape #5.
  case shacl.admit(ttl, opts ++ [shapes: shapes, shape_iri: "tosca:ResourceGroupShape"]) do
    {:ok, r} when r.admitted ->
      IO.puts("[PASS] full canonical shapes graph accepted by REAL engine; conforming instance admitted")
    other ->
      IO.puts("[FAIL] engine leg 1: #{inspect(other)}")
      System.halt(1)
  end

  # Leg 2: mutated instance refused (sh:closed).
  case shacl.admit(mutated, opts ++ [shapes: shapes, shape_iri: "tosca:ResourceGroupShape"]) do
    {:refused, :smalt_shacl_violation, _} ->
      IO.puts("[PASS] mutated instance refused :smalt_shacl_violation")
    other ->
      IO.puts("[FAIL] engine leg 2 (vacuous gate): #{inspect(other)}")
      System.halt(1)
  end

  IO.puts("VERDICT: ALIVE [GREEN] - engine-level admission court green")
  System.halt(0)
else
  {:error, refusal} -> IO.puts("[FAIL] engine unavailable: #{inspect(refusal)}"); System.halt(1)
  false -> IO.puts("[FAIL] host never available"); System.halt(1)
end
