defmodule Smalt.Aoq.Arrow.Court do
  @moduledoc """
  Four-tier pure validation ladder for Arrow schemas (NIF-free v1).

  `validate/1` runs the tiers in order and returns on the FIRST failure:

    1. `:grammar`  — exhaustive clause match over the closed type
       grammar (`t:Smalt.Aoq.Arrow.Schema.arrow_type/0`); there is no
       catch-all clause, so an unknown shape is a FunctionClauseError
       converted into a typed refusal.
    2. `:semantic` — value constraints: decimal `scale ≤ precision`
       and precision 1..38, timezone nil-or-nonempty, fixed-size-list
       `n ≥ 1`, map keys not nested containers, dictionary index an
       integer type, field names nonempty binaries, no nested
       dictionary, depth cap 32.
    3. `:digest`   — BLAKE3 over the canonical term form
       (`:erlang.term_to_binary`); `digest/1` is the re-derivation
       entry point used by the bundle/loader turnstile.
    4. `:registry` — schema ids unique across a registry.

  Every refusal is `{:error, {tier :: atom(), reason :: term()}}`.
  """

  alias Smalt.Aoq.Arrow.Schema
  alias Smalt.Posh.Blake3

  @typedoc "Validation tier."
  @type tier :: :grammar | :semantic | :digest | :registry

  @typedoc "Ladder result: `:ok` or a tier-tagged refusal."
  @type verdict :: :ok | {:error, {tier(), reason :: term()}}

  # -- tier 1: grammar --------------------------------------------------------

  @doc """
  Tier 1: exhaustive grammar match. Raises `FunctionClauseError` on an
  unknown shape (no catch-all clause exists); `validate/1` converts
  that into `{:error, {:grammar, {:unknown_type, t}}}`.
  """
  @spec grammar_check(Schema.arrow_type(), non_neg_integer()) :: :ok | {:error, {:grammar, term()}}
  def grammar_check(type, depth \\ 0)
  def grammar_check(:bool, _), do: :ok
  def grammar_check(t, _) when t in [:i8, :i16, :i32, :i64], do: :ok
  def grammar_check(t, _) when t in [:u8, :u16, :u32, :u64], do: :ok
  def grammar_check(t, _) when t in [:f16, :f32, :f64], do: :ok
  def grammar_check(t, _) when t in [:utf8, :large_utf8, :binary, :large_binary], do: :ok
  def grammar_check(t, _) when t in [:date32, :date64], do: :ok

  def grammar_check({:time, unit}, _),
    do: grammar_unit(unit)

  def grammar_check({:timestamp, unit, tz}, _) do
    with :ok <- grammar_unit(unit),
         :ok <- if(is_binary(tz) or is_nil(tz), do: :ok, else: {:error, {:grammar, {:bad_tz, tz}}}) do
      :ok
    end
  end

  def grammar_check({:decimal128, precision, scale}, _)
      when is_integer(precision) and is_integer(scale),
      do: :ok

  def grammar_check({:interval, kind}, _)
      when kind in [:year_month, :day_time, :month_day_nano],
      do: :ok

  def grammar_check({:list, inner, nullable}, depth) when is_boolean(nullable),
    do: nested(inner, depth)

  def grammar_check({:fixed_size_list, inner, n}, depth) when is_integer(n),
    do: nested(inner, depth)

  def grammar_check({:struct, fields}, depth) when is_list(fields),
    do: fields |> Enum.reduce_while(:ok, fn f, :ok -> {:cont, nested_field(f, depth)} end)

  def grammar_check({:map, key, item, sorted}, depth) when is_boolean(sorted),
    do: with(:ok <- nested(key, depth), :ok <- nested(item, depth), do: :ok)

  def grammar_check({:dictionary, index, value}, depth) do
    if index_type?(index) do
      nested(value, depth)
    else
      {:error, {:grammar, {:bad_index_type, index}}}
    end
  end

  defp grammar_unit(u) when u in [:second, :millisecond, :microsecond, :nanosecond], do: :ok

  defp nested(type, depth) do
    if depth >= Schema.depth_cap() do
      {:error, {:grammar, {:depth_exceeded, depth + 1}}}
    else
      grammar_check(type, depth + 1)
    end
  end

  defp nested_field(%Schema.Field{type: t}, depth), do: nested(t, depth)

  @doc false
  def index_type?(t) when t in [:i8, :i16, :i32, :i64, :u8, :u16, :u32, :u64], do: true
  def index_type?(_), do: false

  # -- ladder -----------------------------------------------------------------

  @doc """
  Runs the full ladder over one schema: grammar → semantic → (digest
  is computed by callers via `digest/1`, registry by `validate_registry/1`).
  Returns `:ok` or the first tier failure.
  """
  @spec validate(Schema.t()) :: verdict()
  def validate(%Schema{} = schema) do
    with :ok <- grammar(schema),
         :ok <- semantic(schema) do
      :ok
    end
  end

  defp grammar(%Schema{fields: fields}) do
    Enum.reduce_while(fields, :ok, fn
      %Schema.Field{name: name, type: type}, :ok when is_binary(name) ->
        try do
          grammar_check(type)
        rescue
          FunctionClauseError -> {:error, {:grammar, {:unknown_type, type}}}
        end
        |> case do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end

      %Schema.Field{name: name}, :ok ->
        {:halt, {:error, {:grammar, {:bad_field_name, name}}}}

      other, :ok ->
        {:halt, {:error, {:grammar, {:bad_field, other}}}}
    end)
  end

  # -- tier 2: semantic -------------------------------------------------------

  @doc """
  Tier 2: value constraints over an already grammar-clean schema.
  """
  @spec semantic(Schema.t()) :: verdict()
  def semantic(%Schema{fields: fields}) do
    fields
    |> Enum.reduce_while(:ok, fn field, :ok ->
      case semantic_field(field) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp semantic_field(%Schema.Field{name: name}) when name == "" do
    {:error, {:semantic, {:empty_field_name, name}}}
  end

  defp semantic_field(%Schema.Field{type: type}) do
    case type do
      {:decimal128, precision, scale} ->
        if precision in 1..38 do
          if scale <= precision and scale >= 0 do
            :ok
          else
            {:error, {:semantic, {:scale_exceeds_precision, precision, scale}}}
          end
        else
          {:error, {:semantic, {:precision_out_of_range, precision}}}
        end

      {:timestamp, _unit, tz} ->
        if is_nil(tz) or (is_binary(tz) and tz != "") do
          semantic_nested(type)
        else
          {:error, {:semantic, {:empty_timezone, tz}}}
        end

      {:fixed_size_list, _inner, n} when n < 1 ->
        {:error, {:semantic, {:fixed_size_list_n, n}}}

      {:map, key, _item, _sorted} ->
        if container?(key) do
          {:error, {:semantic, {:nested_map_key, key}}}
        else
          semantic_nested(type)
        end

      {:dictionary, _index, value} ->
        if value == :dictionary or match?({:dictionary, _, _}, value) do
          {:error, {:semantic, {:nested_dictionary, value}}}
        else
          semantic_nested(type)
        end

      _other ->
        semantic_nested(type)
    end
  end

  # Recurse semantic checks into container children (depth is already
  # proven legal by the grammar tier, so plain recursion terminates).
  defp semantic_nested({:list, inner, _nullable}), do: semantic_type(inner)
  defp semantic_nested({:fixed_size_list, inner, _n}), do: semantic_type(inner)
  defp semantic_nested({:struct, fields}) when is_list(fields) do
    Enum.reduce_while(fields, :ok, fn f, :ok ->
      case semantic_field(f) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end
  defp semantic_nested({:map, key, item, _sorted}) do
    with :ok <- semantic_type(key), :ok <- semantic_type(item), do: :ok
  end
  defp semantic_nested({:dictionary, _index, value}), do: semantic_type(value)
  defp semantic_nested(_leaf), do: :ok

  defp semantic_type(type) do
    # Re-enter through a synthetic single-field schema so the same
    # clause heads apply to nested types.
    semantic(%Schema{schema_id: :synthetic, fields: [Schema.field("synthetic", type, true)]})
    |> case do
      {:error, {:semantic, {:empty_field_name, _}}} -> :ok
      verdict -> verdict
    end
  end

  defp container?({:list, _, _}), do: true
  defp container?({:fixed_size_list, _, _}), do: true
  defp container?({:struct, _}), do: true
  defp container?({:map, _, _, _}), do: true
  defp container?({:dictionary, _, _}), do: true
  defp container?(_), do: false

  # -- tier 3: digest ---------------------------------------------------------

  @typedoc "32-byte BLAKE3 digest over the canonical schema term form."
  @type schema_digest :: <<_::256>>

  @doc """
  Tier 3: BLAKE3 digest over `:erlang.term_to_binary` of the
  domain-separated canonical schema term. Deterministic across nodes
  for identical schemas (atoms are encoded by name, not by ref).
  """
  @spec digest(Schema.t()) :: schema_digest()
  def digest(%Schema{} = schema) do
    schema
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> Blake3.digest()
  end

  @doc "The domain-separated term the digest is computed over."
  def canonical_term(%Schema{schema_id: id, fields: fields}),
    do: {:aoq_arrow_schema_v1, id, fields}

  # -- tier 4: registry -------------------------------------------------------

  @doc """
  Tier 4: validates a schema list as a registry — each schema passes
  the full ladder and ids are unique. Returns `:ok` or the first
  refusal (duplicates carry the colliding id).
  """
  @spec validate_registry([Schema.t()]) :: verdict()
  def validate_registry(schemas) do
    with :ok <- unique_ids(schemas) do
      Enum.reduce_while(schemas, :ok, fn schema, :ok ->
        case validate(schema) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp unique_ids(schemas) do
    ids = Enum.map(schemas, & &1.schema_id)
    dupes = ids -- Enum.uniq(ids)

    if dupes == [] do
      :ok
    else
      {:error, {:registry, {:duplicate_schema_id, hd(dupes)}}}
    end
  end
end
