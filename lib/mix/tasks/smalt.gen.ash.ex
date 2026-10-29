defmodule Mix.Tasks.Smalt.Gen.Ash do
  @shortdoc "Project the smalt ARM ontology into Ash domains/resources via ggen + Igniter"

  @moduledoc """
  Extraction rides ggen_igniter (fixed graphlaw engine); synthesis rides Igniter.

      mix smalt.gen.ash <ontology.ttl> [--dry-run]

  The ontology is the bicep-derived Turtle (azure_8020.ttl from
  bicep_to_ttl.exs) or any substrate-pack-style graph using the harmonized
  dual-vocabulary queries below.

  Emits (all idempotent, replay-deterministic):
  * lib/smalt/<domain_snake>/<resource_snake>.ex - Ash.Resource (ETS datalayer,
    shallow 80/20 attributes, arm_put/arm_delete/get_by_arm_id actions,
    admitted-parent belongs_to)
  * lib/smalt/<domain_snake>.ex - Ash.Domain with a resources block
  * lib/smalt/ash_gen/registry.ex - {provider, type_path} -> {module, api_version}

  --dry-run is framework-handled by Igniter.Mix.Task (diff, no writes).
  """

  use Igniter.Mix.Task

  @bindings_query ~S"""
  PREFIX s: <https://ggen.io/ontology/smalt#>
  PREFIX b: <https://smalt.local/ontology/arm#>
  SELECT ?resource_type ?api_version ?ash_resource ?ash_domain ?arm_uri_template ?bicep_ref WHERE {
    { ?res b:resourceType ?resource_type ; b:ashResource ?ash_resource ;
           b:armUriTemplate ?arm_uri_template ; b:hasBinding ?tb .
      ?tb b:apiVersion ?api_version .
      OPTIONAL { ?tb b:bicepRef ?bicep_ref }
      OPTIONAL { ?res b:provider ?prov . ?prov b:ashDomain ?ash_domain } }
    UNION
    { ?tb s:resourceType ?resource_type ; s:apiVersion ?api_version .
      OPTIONAL { ?tb s:bicepRef ?bicep_ref } }
  }
  """

  @parents_query ~S"""
  PREFIX s: <https://ggen.io/ontology/smalt#>
  PREFIX b: <https://smalt.local/ontology/arm#>
  SELECT ?child_type ?parent_type WHERE {
    { ?child s:contains ?p . ?p s:resourceType ?parent_type . ?child s:resourceType ?child_type }
    UNION
    { ?child b:parent ?p . ?p b:resourceType ?parent_type . ?child b:resourceType ?child_type }
  }
  """

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      positional: [{:ontology, optional: true}],
      schema: [provider: :keep],
      example: "mix smalt.gen.ash tmp/azure_8020.ttl [--provider Microsoft.Network]"
    }
  end

  # Non-tty fix (wave-1 L6 witness): igniter's long-diff handler
  # (handle_long_diff -> Igniter.Util.IO.select/3) prompts even under
  # --dry-run and crashes on :eof stdin (String.trim(:eof)) when stdout is
  # redirected. run/1 is defoverridable in Igniter.Mix.Task; injecting --yes
  # on non-tty makes CI deterministic without patching upstream. --dry-run
  # still never writes (do_or_dry_run checks opts[:dry_run] before the write
  # gate).
  @impl Mix.Task
  def run(argv) do
    argv =
      if terminal?() or "--yes" in argv do
        argv
      else
        argv ++ ["--yes"]
      end

    super(argv)
  end

  defp terminal?, do: :io.getopts() |> Keyword.get(:terminal, false)

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    path = igniter.args.positional.ontology

    unless is_binary(path) do
      Mix.raise("usage: mix smalt.gen.ash <ontology.ttl> - e.g. mix smalt.gen.ash tmp/azure_8020.ttl")
    end

    unless Code.ensure_loaded?(GgenIgniter.Ontology) do
      Mix.raise("GgenIgniter not loaded - ggen_igniter is a dev-only dep; run with MIX_ENV=dev")
    end

    graph =
      try do
        GgenIgniter.Ontology.load!(path)
      rescue
        e -> Mix.raise("failed to load ontology #{path}: #{Exception.message(e)}")
      end

    bindings = GgenIgniter.Query.run(graph, @bindings_query)
    parents = GgenIgniter.Query.run(graph, @parents_query)
    models = Smalt.AshGen.Model.from_sparql_rows(%{bindings: bindings, parents: parents})
    providers = List.wrap(igniter.args.options[:provider] || [])

    models = Smalt.AshGen.Model.filter_by_providers(models, providers)
    Mix.shell().info("smalt.gen.ash: #{length(models)} resource models from #{path}")

    igniter
    |> Smalt.AshGen.Generator.generate(models)
  end
end
