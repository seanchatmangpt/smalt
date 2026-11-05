defmodule Smalt.Aoq.Arrow.Loader do
  @moduledoc """
  Boot-source loader for the AOQ Arrow schema registry (NIF-free v1).

  `load/1` reads the schema bundle (`Smalt.Aoq.Arrow.Bundle.decode/1`),
  runs every schema through the four-tier court
  (`Smalt.Aoq.Arrow.Court`), and re-derives the BLAKE3 digest — the
  bundled digest is a pinned claim, never trusted as truth. On any
  refusal the load fails closed with the court verdict.

  Result: `{:ok, %{schema_id => %{schema: %Schema{}, digest: <<_::256>>}}}`.

  An empty bundle is lawful and yields `%{}` — byte-identical with the
  current compile-time `@arrow_schemas %{}` in `Smalt.Aoq.Tables`.

  ## Supervisor wiring (disclosed, applied by the owner lane)

  To make the bundle the boot source for `{:aoq, :arrow_schemas}`,
  `lib/smalt/aoq/supervisor.ex` (owner lane) passes the loaded map into
  the boot:

  ```elixir
  {:ok, schemas} = Smalt.Aoq.Arrow.Loader.load()   # in Supervisor.init
  Tables.boot(arrow_schemas: schemas)
  ```
  """

  alias Smalt.Aoq.Arrow.Bundle
  alias Smalt.Aoq.Arrow.Court

  @doc """
  Loads, courts, and digest-verifies the bundle at `path`
  (default: `Smalt.Aoq.Arrow.Bundle.default_path/0`).
  """
  @spec load(Path.t()) ::
          {:ok, %{Smalt.Aoq.Arrow.Schema.schema_id() => %{schema: Smalt.Aoq.Arrow.Schema.t(), digest: Court.schema_digest()}}}
          | {:error, term()}
  def load(path \\ Bundle.default_path()) do
    with {:ok, entries} <- Bundle.decode(path) do
      court_entries(entries)
    end
  end

  defp court_entries(entries) do
    schemas = schema_list(entries)

    with :ok <- Court.validate_registry(schemas) do
      verified =
        Enum.reduce_while(entries, {:ok, %{}}, fn {id, %{schema: schema, digest: digest}}, {:ok, acc} ->
          case Court.digest(schema) do
            ^digest -> {:cont, {:ok, Map.put(acc, id, %{schema: schema, digest: digest})}}
            computed -> {:halt, {:error, {:digest_mismatch, id, bundled: digest, computed: computed}}}
          end
        end)

      verified
    end
  end

  defp schema_list(entries) do
    entries |> Map.values() |> Enum.map(& &1.schema)
  end
end
