defmodule Smalt.AshGen.Generator do
  @moduledoc """
  Igniter AST synthesis of Ash domains/resources from `Smalt.AshGen.Model`s.

  Pipeline: ggen (graphlaw SPARQL in the Mix task) -> `Smalt.AshGen.Model`
  structs -> Igniter patches:

  1. Per provider-domain: create the `use Ash.Domain` module, or register new
     resources into an existing domain's `resources do ... end` block via
     zipper edits (idempotent: membership-checked before insertion).
  2. Per model: create the `Ash.Resource` (ETS datalayer) with the shallow
     80/20 attribute set, lifecycle actions, and an admitted-parent-only
     `belongs_to :parent` relationship.
  3. Project the `{provider, type_path}` -> `{module, api_version}` registry
     to `lib/smalt/ash_gen/registry.ex` (DO-NOT-EDIT; regenerated each run,
     same content is a zero diff).
  """

  @registry_path "lib/smalt/ash_gen/registry.ex"

  @doc "Applies all patches to `igniter` for `models` (sorted, deterministic)."
  @spec generate(Igniter.t(), [Smalt.AshGen.Model.t()]) :: Igniter.t()
  def generate(igniter, models) do
    igniter
    |> generate_domains_and_resources(models)
    |> write_registry(models)
  end

  # ── domains + resources ──────────────────────────────────────────────

  defp generate_domains_and_resources(igniter, models) do
    models
    |> Enum.group_by(& &1.domain_module)
    |> Enum.sort_by(fn {domain, _} -> inspect(domain) end)
    |> Enum.reduce(igniter, fn {domain, domain_models}, ign ->
      resource_modules =
        domain_models
        |> Enum.map(& &1.resource_module)
        |> Enum.uniq()
        |> Enum.sort()

      ign
      |> ensure_domain(domain, resource_modules)
      |> create_resources(domain_models)
    end)
  end

  # Existence judged by deterministic lib path + disk/rewrite state — never
  # via Igniter.Project.Module.module_exists/find_module, whose
  # try_directory_search fallback deep-globs the tree and trips Rewrite's 5s
  # read timeout on this repo (witnessed 2x on the slice-1 landing).
  defp module_path(igniter, module) do
    Igniter.Project.Module.proper_location(igniter, module, :source_folder)
  end

  defp module_exists(igniter, module) do
    path = module_path(igniter, module)

    cond do
      Rewrite.has_source?(igniter.rewrite, path) -> true
      # host-disk arm is real-project-only: in Igniter.Test's virtual project
      # the host disk is NOT project state (witnessed: landed slice files made
      # every test take the register path and find_module fail).
      igniter.assigns[:test_mode?] -> false
      true -> File.exists?(path)
    end
  end

  defp ensure_domain(igniter, domain, resource_modules) do
    if module_exists(igniter, domain) do
      register_all_in_domain(igniter, domain, resource_modules)
    else
      Igniter.Project.Module.create_module(igniter, domain, domain_body(resource_modules))
    end
  end

  defp register_all_in_domain(igniter, domain, resource_modules) do
    path = module_path(igniter, domain)
    igniter = Igniter.include_existing_file(igniter, path)

    Enum.reduce(resource_modules, igniter, fn resource, ign ->
      Igniter.Project.Module.find_and_update_module!(ign, domain, fn zipper ->
        register_in_resources_block(zipper, resource)
      end)
    end)
  end

  # Self-contained (no ash_domains config coupling): upstream
  # Ash.Domain.Igniter.add_resource_reference/3 was evaluated and rejected —
  # its list_domains/1 discovery reads Application.get_env(app, :ash_domains);
  # with no config row it falls into upgrade_plain_module_to_domain, which
  # rewrites our domains and injects an ash_domains config line, breaking
  # replay idempotency (witnessed by the idempotency test).
  def register_in_resources_block(zipper, resource) do
    existing =
      Igniter.Code.Function.move_to_function_call(
        zipper,
        :resource,
        1,
        &Igniter.Code.Function.argument_equals?(&1, 0, resource)
      )

    case existing do
      {:ok, zipper} ->
        {:ok, zipper}

      :error ->
        with {:ok, zipper} <- Igniter.Code.Function.move_to_function_call(zipper, :resources, 1),
             {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
          {:ok, Igniter.Code.Common.add_code(zipper, "resource " <> inspect(resource), placement: :after)}
        else
          :error -> {:warning, "no resources block found for " <> inspect(resource)}
        end
    end
  end

  defp create_resources(igniter, models) do
    Enum.reduce(models, igniter, fn model, ign ->
      if module_exists(ign, model.resource_module) do
        ign
      else
        Igniter.Project.Module.create_module(ign, model.resource_module, resource_body(model))
      end
    end)
  end

  # ── registry projection ──────────────────────────────────────────────

  # Slice-composable merge law (wave-1 L6): a --provider slice run unions its
  # entries with any previously landed registry; a full run is the fixed point.
  # Existing entries are read from the compiled module (task runs in dev after
  # compile); a test project never has it loaded, so the plain write keeps the
  # idempotency court exact.
  defp write_registry(igniter, models) do
    existing =
      if Code.ensure_loaded?(Smalt.AshGen.Registry) do
        Smalt.AshGen.Registry.entries()
      else
        %{}
      end

    # models win on collision; existing (previously landed slices) fill gaps.
    # The reversed merge let a stale beam overwrite the run's own entries —
    # witnessed: fixture api-version shim left the registry untouched.
    merged =
      existing
      |> Map.merge(
        models
        |> Enum.map(fn m -> {{m.provider, type_path(m)}, {m.resource_module, m.api_version}} end)
        |> Map.new()
      )
      |> Enum.sort_by(fn {{p, t}, _} -> {p, t} end)
      |> Map.new()

    Igniter.create_new_file(igniter, @registry_path, registry_content_from(merged), on_exists: :overwrite)
  end

  defp registry_content_from(merged) do
    entries =
      Enum.map(merged, fn {{p, t}, {mod, ver}} ->
        key = "{#{inspect(p)}, #{inspect(t)}}"
        "      #{key} => {#{inspect(mod)}, #{inspect(ver)}}"
      end)

    """
    defmodule Smalt.AshGen.Registry do
      @moduledoc \"\"\"
      {provider, type_path} -> {resource_module, api_version} for the projected
      Ash surface. DO NOT EDIT — regenerate with `mix smalt.gen.ash <ontology.ttl>`.
      \"\"\"

      @mapping %{
#{Enum.join(entries, ",\n")}
      }

      @spec lookup(String.t(), String.t()) :: {module(), String.t()} | nil
      def lookup(provider, type_path) do
        Map.get(@mapping, {provider, type_path})
      end

      @spec entries() :: map()
      def entries, do: @mapping
    end
    """
  end

  defp type_path(%{resource_type: rt}) do
    rt
    |> String.split("/")
    |> tl()
    |> Enum.join("/")
  end

  # ── generated bodies ─────────────────────────────────────────────────

  defp domain_body(resource_modules) do
    lines = Enum.map_join(resource_modules, "\n", fn m -> "    resource #{inspect(m)}" end)

    """
    @moduledoc \"""
    Ash domain projected from the smalt ARM type ontology.
    DO NOT EDIT — regenerate with `mix smalt.gen.ash <ontology.ttl>`.
    \"""

    use Ash.Domain, validate_config_inclusion?: false

    resources do
#{lines}
    end
    """
  end

  defp resource_body(model) do
    rel = parent_relationship(model)

    """
    @moduledoc \"""
    #{model.resource_type} (api-version #{model.api_version})

    Projected from the smalt ARM type ontology by `mix smalt.gen.ash`.
    DO NOT EDIT — regenerate with `mix smalt.gen.ash <ontology.ttl>`.
    \"""

    use Ash.Resource, domain: #{inspect(model.domain_module)}, data_layer: Ash.DataLayer.Ets

    attributes do
      attribute :arm_id, :string, primary_key?: true, allow_nil?: false
      attribute :name, :string
      attribute :location, :string
      attribute :tags, :map, default: %{}
      attribute :properties, :map, default: %{}
      attribute :provisioning_state, :string, default: "Succeeded"
    end

    actions do
      defaults [:read]
      read :get_by_arm_id, get_by: [:arm_id]

      create :arm_put do
        accept [:arm_id, :name, :location, :tags, :properties]
        upsert? true
      end

      destroy :arm_delete
    end
#{rel}
    """
  end

  defp parent_relationship(nil), do: ""

  defp parent_relationship(model) do
    pm = model.parent_module

    if pm && pm != model.resource_module do
      """
          relationships do
            belongs_to :parent, #{inspect(pm)} do
              destination_attribute :arm_id
              attribute_writable? false
            end
          end
      """
    else
      ""
    end
  end
end
