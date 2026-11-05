defmodule Smalt.Aoq.SchemaBindings do
  @moduledoc """
  Lane-16 (v26.11.6) schema-binding table for the AoQ RDF projector: the
  `{:aoq, :schema_bindings}` `:persistent_term` snapshot, boot-only sealed
  write, hot read.

  Snapshot shape (ONE key, so the projector's drain boundary costs ONE
  `:persistent_term.get`):

      %{
        bindings: %{eh_guid => arrow_schema_id},
        schemas:  %{arrow_schema_id => compiled Arrow schema term}
      }

  Derivation (boot only, never ingest):

  - `bindings` is derived from the verified Arrow bundle manifest entries
    (`Smalt.Aoq.Arrow.Bundle.decode/1` ids) crossed with EH registry group
    records (`Smalt.Messaging.EhSchemaRegistry.list_groups/0`-shaped
    `%{eh_guid => ...}` records injected at boot). `register_schema/2`
    exists as an OPTIONAL binding hook for the `eh_schema_registry.ex` owner
    (disclosed, unrouted — every call path post-boot raises sealed-error,
    exactly like `Smalt.Aoq.Tables.put_arrow_schema/2`).
  - `schemas` mirrors the `{:aoq, :arrow_schemas}` registry contents passed
    at the same boot, so the projector never needs a second table read.

  Sealing law is `Smalt.Aoq.Tables`' law: write once at boot from the boot
  source, seal, then every non-boot mutation path raises a typed error.
  Ingest NEVER mutates: the projector reads the snapshot; an unbound schema
  is a typed fail-closed refusal at the drain boundary
  (`:aoq_schema_unbound`), never a write.
  """

  @binding_key {:aoq, :schema_bindings}
  @seal_key {:aoq, :schema_bindings_sealed}

  @typedoc "The immutable boot snapshot read at the drain boundary."
  @type snapshot :: %{
          required(:bindings) => %{String.t() => term()},
          required(:schemas) => %{term() => term()}
        }

  @doc """
  Writes the `{:aoq, :schema_bindings}` snapshot and seals it. Idempotent
  re-derivation via a second `boot/1` is the only lawful mutation class.

  Opts:

    - `:bindings` — `%{eh_guid => arrow_schema_id}` (default `%{}`).
    - `:schemas` — `%{arrow_schema_id => schema term}` (default: the
      `:arrow_schemas` opt, i.e. the same map the Arrow boot hands
      `Smalt.Aoq.Tables.boot/1`; pass explicitly to diverge, test only).

  Returns the snapshot written.
  """
  @spec boot(keyword()) :: snapshot()
  def boot(opts \\ []) do
    arrow_schemas = Keyword.get(opts, :arrow_schemas, %{})
    schemas = Keyword.get(opts, :schemas, arrow_schemas)
    bindings = Keyword.get(opts, :bindings, %{})

    snapshot = %{bindings: bindings, schemas: schemas}
    :persistent_term.put(@binding_key, snapshot)
    :persistent_term.put(@seal_key, System.unique_integer([:monotonic]))
    snapshot
  end

  @doc """
  THE drain-boundary read: one `:persistent_term.get`, whole snapshot.
  Raises if unbooted — an unbooted bindings table is a boot-order defect,
  not a runtime condition (same law as `Smalt.Aoq.Tables` hot reads).
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    :persistent_term.get(@binding_key)
  end

  @doc "Binding for one EH GUID, `{:ok, schema_id}` or `{:error, :aoq_schema_unbound}`."
  @spec binding(String.t()) :: {:ok, term()} | {:error, :aoq_schema_unbound}
  def binding(eh_guid) when is_binary(eh_guid) do
    case snapshot().bindings do
      %{^eh_guid => schema_id} -> {:ok, schema_id}
      _ -> {:error, :aoq_schema_unbound}
    end
  end

  @doc """
  OPTIONAL binding hook, disclosed for the `eh_schema_registry.ex` owner
  (LANE-16 does not route any caller here; the module does not edit that
  file). Mirrors `Smalt.Aoq.Tables.put_arrow_schema/2` sealing law exactly:
  raises a typed `ArgumentError` both pre-boot and post-boot — the only
  lawful mutation is a full `boot/1` re-derivation.
  """
  @spec register_schema(String.t(), term()) :: no_return()
  def register_schema(_eh_guid, _schema_id) do
    case :persistent_term.get(@seal_key, nil) do
      nil ->
        raise ArgumentError,
              "AOQ schema bindings not booted; call Smalt.Aoq.SchemaBindings.boot/1 first"

      _seal ->
        raise ArgumentError,
              "AOQ schema bindings sealed at boot (post-boot write refused); " <>
                "re-derive via Smalt.Aoq.SchemaBindings.boot/1"
    end
  end

  @doc "True when the bindings table has been booted (seal key present)."
  @spec sealed?() :: boolean()
  def sealed? do
    :persistent_term.get(@seal_key, nil) != nil
  end
end
