defmodule Mix.Tasks.Smalt.Seed do
  @shortdoc "Seed local ARM state from an exported Azure resource corpus (JSON array)."

  @moduledoc """
  Reads an exported Azure resource corpus — a JSON array of
  `{id, name, type, location, properties}` objects, exported once from real
  Azure with `az resource list --output json` plus `az resource show` bodies —
  and hydrates the local ARM store (`Smalt.Store`, `:smalt_resources` table)
  so the seeded resources GET compatibly with hand-PUT ones, without ever
  having PUT them locally (T-02 resource pre-seeding).

  Seeding is state hydration, not cloud actuation: it lives in the Elixir
  substrate tooling, never `smalt-cli` (AU-10 gate — the CLI companion stays
  actuation-free). No live Azure connectivity: the export happens on the
  developer's machine with their own `az` session; smalt never phones out.

  ## Usage

      mix smalt.seed --file corpus.json
      mix smalt.seed --file corpus.json --dry-run

  Normalization per entry (Store row law — the same conventions the ARM PUT
  paths materialize, cf. `test/integration/sb_arm_rules_test.exs`):

    * the STORE KEY is the downcased resource id (all Store tables key on
      lowercased full ARM id strings); the record's wire `"id"` member keeps
      the corpus casing;
    * `name`/`type`/`location`/`properties` are preserved verbatim;
    * `properties.provisioningState` defaults to `"Succeeded"` when the
      corpus omits it (the same persist-time default the generic PUT applies
      via `build_resource_record/5`); `location` defaults to `"eastus"` when
      the corpus omits it (same raw-payload fallback law);
    * any other top-level wire members the corpus carries (`tags`, `sku`,
      `kind`, ...) pass through untouched, so `GET` echoes what the real
      cloud showed.

  `--dry-run` prints the would-be seeded ids and writes nothing. Re-runs are
  idempotent: `Store.put/3` is a same-key overwrite, so a double seed is a
  no-op (idempotency receipt face).

  Exit contract: typed `[smalt] ERROR` to stderr + exit 1 on a missing or
  unreadable file, malformed JSON, or a malformed entry — never a raise, and
  all-or-nothing: a corpus with any malformed entry writes nothing.
  """

  use Mix.Task

  alias Mix.Tasks.Smalt.EnclaveCommon
  alias Smalt.Store

  @switches [file: :string, dry_run: :boolean]
  @aliases [f: :file]
  @resource_table :smalt_resources

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      "--help" in args or opts[:help] ->
        EnclaveCommon.help!(@moduledoc)

      invalid != [] or argv != [] ->
        EnclaveCommon.fail!(
          ":bad_args task=smalt.seed invalid=#{inspect(invalid)} argv=#{inspect(argv)}"
        )

      true ->
        main(opts)
    end
  end

  defp main(opts) do
    file = EnclaveCommon.require_flag!(opts, :file, "smalt.seed")
    dry_run? = opts[:dry_run] == true

    with {:ok, path, raw} <- read_corpus(file),
         {:ok, entries} <- decode_corpus(raw, path),
         {:ok, records} <- normalize_corpus(entries) do
      if dry_run? do
        # Dry-run never boots the Store: print the would-be ids, write nothing.
        Enum.each(records, fn {_key, record} ->
          Mix.shell().info("[seed:dry-run] #{record["id"]}")
        end)

        Mix.shell().info("[seed] DRY-RUN file=#{path} would_seed=#{length(records)} wrote=0")
        :ok
      else
        EnclaveCommon.ensure_store!()

        Enum.each(records, fn {key, record} ->
          Store.put(@resource_table, key, record)
        end)

        Mix.shell().info("[seed] OK file=#{path} seeded=#{length(records)} table=:smalt_resources")
        :ok
      end
    else
      {:error, reason} ->
        EnclaveCommon.fail!(":seed_failed task=smalt.seed reason=#{inspect(reason, limit: 20)}")
    end
  end

  # -- typed corpus ingestion (never a raise, all-or-nothing) ------------------

  defp read_corpus(file) do
    path = Path.expand(file)

    case File.read(path) do
      {:ok, raw} ->
        {:ok, path, raw}

      {:error, reason} ->
        {:error, {:file_unreadable, path: path, reason: inspect(reason)}}
    end
  end

  defp decode_corpus(raw, path) do
    case Jason.decode(raw) do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries}

      {:ok, _other} ->
        {:error, {:malformed_corpus, path: path, expected: "a JSON array of resource objects"}}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, {:malformed_json, path: path, message: Exception.message(e)}}
    end
  end

  # Validate EVERY entry first: a corpus with any malformed entry writes
  # nothing (fail-closed hydration, not a partial seed).
  defp normalize_corpus(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
      case normalize_entry(entry, idx) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _} = err -> err
    end
  end

  # Store row law: downcased id KEY, record preserving the corpus body with
  # the PUT-path defaults applied. `with` without else falls through with the
  # first non-matching value (a typed {:error, _} from fetch_binary/3).
  defp normalize_entry(%{} = entry, idx) do
    with {:ok, id} <- fetch_binary(entry, "id", idx),
         {:ok, name} <- fetch_binary(entry, "name", idx),
         {:ok, type} <- fetch_binary(entry, "type", idx) do
      record =
        entry
        # The wire id keeps the corpus casing; only the STORE KEY downcases.
        |> Map.put("id", id)
        |> Map.put("name", name)
        |> Map.put("type", type)
        |> Map.put("location", Map.get(entry, "location", "eastus"))
        |> Map.put("properties", defaulted_properties(Map.get(entry, "properties")))

      {:ok, {String.downcase(id), record}}
    end
  end

  defp normalize_entry(entry, idx) do
    {:error,
     {:bad_entry, index: idx, expected: "a JSON object with id/name/type strings",
      got: inspect(entry, limit: 5)}}
  end

  defp fetch_binary(entry, field, idx) do
    case Map.fetch(entry, field) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, value} ->
        {:error, {:bad_entry, index: idx, field: field, expected: "string", got: value}}

      :error ->
        {:error, {:bad_entry, index: idx, field: field, expected: "present"}}
    end
  end

  defp defaulted_properties(props) when is_map(props),
    do: Map.put_new(props, "provisioningState", "Succeeded")

  defp defaulted_properties(_),
    do: %{"provisioningState" => "Succeeded"}
end
