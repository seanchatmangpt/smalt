defmodule Smalt.Aoq.Arrow.Bundle do
  @moduledoc """
  Decode of the Arrow schema bundle (`priv/aoq/arrow_schemas.bundle`).

  The bundle is an Erlang terms file (`:file.consult/1` format):

      {aoq_arrow_bundle, 1}.
      {schema, id, [fields]}.        % fields: [{name, type, nullable, metadata}]
      {digest, id, <<32 bytes>>}.    % BLAKE3 over the canonical schema term

  The magic line `{aoq_arrow_bundle, 1}.` MUST be the first term.
  Fail-closed: a missing file, a consult error, a wrong/missing magic,
  an unknown record tag, or a digest record without a matching schema
  record is a typed refusal — never a silently-empty registry.
  An empty bundle (magic line only) is lawful: it decodes to `%{}`
  (byte-identical with today's empty compile-time registry).
  """

  alias Smalt.Aoq.Arrow.Court
  alias Smalt.Aoq.Arrow.Schema

  @magic {:aoq_arrow_bundle, 1}
  @type entry :: %{required(:schema) => Schema.t(), required(:digest) => Court.schema_digest()}

  @doc "Default bundle path inside the smalt app priv dir."
  @spec default_path() :: String.t()
  def default_path do
    Path.join([Application.app_dir(:smalt, "priv"), "aoq", "arrow_schemas.bundle"])
  end

  @doc """
  Decodes the bundle at `path`. Returns
  `{:ok, %{id => %{schema: %Schema{}, digest: <<_::256>>}}}` or a
  typed `{:error, reason}`.
  """
  @spec decode(Path.t()) :: {:ok, %{Schema.schema_id() => entry()}} | {:error, term()}
  def decode(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        decode_terms(terms)

      {:error, reason} ->
        {:error, {:bundle_consult, path, reason}}
    end
  end

  defp decode_terms([@magic | rest]), do: records(rest, %{}, %{})

  defp decode_terms(other),
    do: {:error, {:bundle_magic, expected: @magic, got: hd(other || [:eof])}}

  # schemas: id => fields ; digests: id => digest. Merge at the end so
  # record order within the file never matters.
  defp records([], schemas, digests) do
    missing =
      Enum.find(Map.keys(schemas), fn id -> not is_map_key(digests, id) end)

    case missing do
      nil ->
        entries =
          Map.new(schemas, fn {id, fields} ->
            {id, %{schema: build_schema(id, fields), digest: Map.fetch!(digests, id)}}
          end)

        {:ok, entries}

      id ->
        {:error, {:bundle_digest_missing, id}}
    end
  end

  defp records([{tag, id, fields} | rest], schemas, digests) when tag == :schema do
    if is_map_key(schemas, id) do
      {:error, {:bundle_duplicate_schema, id}}
    else
      records(rest, Map.put(schemas, id, fields), digests)
    end
  end

  defp records([{tag, id, digest} | rest], schemas, digests) when tag == :digest do
    case digest do
      <<_::256>> -> records(rest, schemas, Map.put(digests, id, digest))
      other -> {:error, {:bundle_bad_digest, id, other}}
    end
  end

  defp records([other | _], _schemas, _digests), do: {:error, {:bundle_record, other}}

  defp build_schema(id, fields) do
    fs =
      Enum.map(fields, fn {name, type, nullable, metadata} ->
        Schema.field(name, type, nullable, metadata)
      end)

    Schema.new(id, fs)
  end
end
