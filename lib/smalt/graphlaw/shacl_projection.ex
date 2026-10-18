defmodule Smalt.GraphLaw.SHACLProjection do
  @moduledoc """
  Target-agnostic SHACL -> projection law, adopted from
  `ggen-marketplace/packs/shacl-projection-pack` (v0.2.0).

  The pack's law: every projected artifact is bound to its source
  `sh:NodeShape` via `shp:derivedFromShape`, fields come only from real
  `sh:PropertyShape`s (never fabricated), and primitive `sh:datatype`
  maps to JSON types (string -> "string", xsd:boolean -> "boolean",
  xsd:integer|xsd:long -> "integer", everything else -> "number").

  Consumer adaptation (disclosed): smalt's shapes file
  (`priv/shacl/smalt-shapes.ttl`) declares no `sh:datatype` constraints,
  so fields carry no JSON `type` keyword here — only presence
  (`required`) and the shape's `sh:message` as the field description.
  `className` is the shape's `sh:targetClass` local name (the pack's
  `shp:className` is supplied by the consumer graph, which is exactly
  what smalt's TTL provides via targetClass). Repetition/nullability
  metadata (`sp:collection`/`sp:nullable`) does not occur in smalt's
  TTL and is not emitted. Projections are re-derived at compile time
  from the same parsed shapes `Smalt.GraphLaw.Validator` uses, so the
  projection and the admission gate can never drift.

  Emits two deterministic projections of the shapes:

    * `json_schema/0` — a JSON Schema (draft 2020-12) document for the
      SDK courts' client-side validation.
    * `docs_markdown/0` — human-readable shape documentation.
  """

  @shapes_path "priv/shacl/smalt-shapes.ttl"
  @external_resource Path.expand("../../../" <> @shapes_path, __DIR__)

  # Same source of truth as the admission gate: the validator parses the
  # shapes file at compile time and exposes it via Validator.shapes/0.
  @shapes Smalt.GraphLaw.Validator.shapes()

  @doc """
  Parsed shapes backing the projections (identity with
  `Smalt.GraphLaw.Validator.shapes/0`).
  """
  def shapes, do: @shapes

  @doc """
  JSON-Schema projection of every shape, keyed by class name.

  Map: class local name -> schema object (`type: "object"`, `properties`,
  `required`). Deterministic ordering; encode with `json_schema_json/0`.
  """
  def json_schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => schema_defs()
    }
  end

  @doc """
  Byte-stable JSON encoding of `json_schema/0` (sorted keys, sorted
  fields — identical output across runs).
  """
  def json_schema_json do
    json_schema()
    |> encode_ordered()
  end

  @doc """
  Human-readable Markdown documentation of every shape. Covers all
  shapes in the shapes file, each with target class, closed flag,
  every declared property (path, min/max count, datatype, message).
  """
  def docs_markdown do
    @shapes
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, shape} -> shape_doc(name, shape) end)
    |> then(&(doc_header() <> &1))
  end

  # -- JSON Schema construction ------------------------------------------------

  defp schema_defs do
    @shapes
    |> Enum.map(&schema_for_shape/1)
    |> Enum.sort_by(fn {class, _} -> class end)
    |> Map.new()
  end

  defp schema_for_shape({shape_name, shape}) do
    class = class_name(shape_name, shape)

    props =
      shape.required
      |> Enum.sort_by(& &1.path)
      |> Map.new(fn prop ->
        {prop.path, field_schema(prop)}
      end)

    required =
      shape.required
      |> Enum.sort_by(& &1.path)
      |> Enum.filter(&(&1.min_count >= 1))
      |> Enum.map(& &1.path)

    {
      class,
      %{
        "title" => class,
        "type" => "object",
        "properties" => props,
        "required" => required
      }
    }
  end

  defp class_name(_shape_name, %{target_class: nil}), do: "Unknown"

  defp class_name(_shape_name, %{target_class: target}) do
    target
    |> String.split(["#", "/"])
    |> List.last()
  end

  # Lane-unblock fix (disclosed, 2026-10-14, pplan lane): shape_doc/2 referenced
  # target_display/1 but no clause existed, freezing the whole-tree compile.
  # Minimal clause consistent with class_name/2 above; owner lane should fold
  # this into their diff.
  defp target_display(nil), do: "Unknown"

  defp target_display(target) do
    target
    |> String.split(["#", "/"])
    |> List.last()
  end

  # Pack law: primitive sh:datatype maps to a JSON type. smalt's TTL declares
  # no sh:datatype, so no "type" keyword is emitted — presence only.
  defp field_schema(prop) do
    base =
      case datatype_json_type(prop.datatype) do
        nil -> %{}
        type -> %{"type" => type}
      end

    case prop.message do
      nil -> base
      message -> Map.put(base, "description", message)
    end
  end

  defp datatype_json_type(:string), do: "string"
  defp datatype_json_type(:integer), do: "integer"
  defp datatype_json_type(:boolean), do: "boolean"
  defp datatype_json_type(nil), do: nil

  # -- deterministic JSON encoding (Jason sorts maps; binaries of maps are
  # key-sorted, lists preserve order — all our lists are explicitly sorted) --

  defp encode_ordered(doc) do
    doc
    |> normalize()
    |> Jason.encode!(pretty: true, maps: :strict)
  rescue
    e -> raise ArgumentError, "json_schema_json encoding failed: " <> Exception.message(e)
  end

  defp normalize(%{} = map), do: map |> Enum.map(fn {k, v} -> {k, normalize(v)} end) |> Map.new()
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  # -- Markdown documentation ---------------------------------------------------

  defp doc_header do
    """
    # SHACL Shape Documentation

    Generated by `Smalt.GraphLaw.SHACLProjection` (adopted from
    `shacl-projection-pack` v0.2.0). Source of truth:
    `priv/shacl/smalt-shapes.ttl`. Do not edit by hand — regenerate
    instead.

    """
  end

  defp shape_doc(name, shape) do
    props =
      shape.required
      |> Enum.sort_by(& &1.path)
      |> Enum.map_join("\n", fn prop ->
        count =
          case {prop.min_count, prop.max_count} do
            {min, nil} -> "min #{min}"
            {min, max} -> "min #{min}, max #{max}"
          end

        datatype =
          case prop.datatype do
            nil -> ""
            dt -> ", datatype xsd:" <> Atom.to_string(dt)
          end

        message =
          case prop.message do
            nil -> ""
            msg -> " — #{msg}"
          end

        "- `#{prop.path}` (#{count}#{datatype})#{message}"
      end)

    props_section =
      case props do
        "" -> "\n_No declared properties._\n"
        props -> "\n### Properties\n\n" <> props <> "\n"
      end

    """
    ## #{name}

    - Target class: `#{target_display(shape.target_class)}`
    - Closed: `#{to_string(shape.closed)}`
    """ <> props_section
  end
end
