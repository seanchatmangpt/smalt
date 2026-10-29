defmodule Smalt.Egress.SqlIngestRoutes do
  @moduledoc """
  w6R-split delegator (lane GLD-3, v26.10.21): POST /sql-ingest — the SQL
  ingestion wire face.

  Accepts `%{"format" => ..., "mapping_iri" => ..., "data_b64" => ...}` and
  drives the `Smalt.SqlIngest` pipeline (SQLD-2's COPY-block parser) into an
  OCEL 2.0 projection (`Smalt.Ocel` envelope shapes), answering:

    * `201` with the OCEL projection summary — per-table name/columns/rowCount
      plus `ocel.eventCount` / `ocel.objectCount`. The envelope is validated
      with `Smalt.Ocel.validate_envelope/2` before the 201 is sent, so a
      structurally-dangling projection cannot leave over the wire.
    * `422` with the GL-8 `GraphlawRefusal` andon envelope
      (`Smalt.Powl2.AndonWire.http_envelope/2`) when the SHACL/identifier law
      fires on the ingested content — the injection-token refusal travels to
      the ingestion wire face intact: rule_id, diagnostic, agent_message,
      repair_hint, context_digest. Status 422 is the andon pinion: the
      request syntax is well-formed, the *content* is unlawful, and
      satisfying the named rule makes the identical request processable.
    * `400` for malformed requests: invalid JSON, missing/ill-typed fields,
      non-base64 `data_b64`, or an unsupported `format` (only
      `postgres_dump` is wired; `csv`/`sqlite` are loud typed refusals, not
      silent 404s — they become 201-capable when the pipeline gains them).

  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """

  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]
  plug :match
  plug :dispatch

  alias Smalt.SqlIngest
  alias Smalt.Powl2.AndonWire
  alias Smalt.Ocel

  @supported_formats ~w(postgres_dump)

  post "/sql-ingest" do
    conn
    |> with_valid_body(fn conn ->
      ingest(conn, conn.body_params)
    end)
    |> halt_if_sent()
  end

  # Fallthrough catch-all — the moduledoc contract ("unmatched conns pass
  # through un-halted") requires this arm: without it a fallthrough conn
  # raises a FunctionClauseError in do_match/4 (witnessed by probe,
  # 2026-10-29), which a mounted chain renders as a 500. Return the conn
  # untouched so the main router's blob splat + 404 catch-all answer.
  match _ do
    conn
  end

  # This delegator is LAST in the w6r_fallthrough chain: a sent response that
  # returns un-halted falls through to the main router's blob splat and
  # AlreadySentErrors there (kd07 class, witnessed). Halt the moment a
  # response is on the wire.
  defp halt_if_sent(conn) do
    if conn.state in [:sent, :chunked] or conn.halted do
      Plug.Conn.halt(conn)
    else
      conn
    end
  end

  # -- internals --------------------------------------------------------------

  defp ingest(
         conn,
         %{
           "format" => format,
           "mapping_iri" => mapping_iri,
           "data_b64" => data_b64
         }
       )
       when is_binary(format) and is_binary(mapping_iri) and is_binary(data_b64) do
    cond do
      format not in @supported_formats ->
        send_json(conn, 400, %{
          "error" => %{
            "code" => "UnsupportedSqlFormat",
            "message" =>
              "format #{inspect(format)} is not wired; supported: #{Enum.join(@supported_formats, ", ")}"
          }
        })

      true ->
        run_pipeline(conn, format, mapping_iri, data_b64)
    end
  end

  defp ingest(conn, _body) do
    send_json(conn, 400, %{
      "error" => %{
        "code" => "InvalidSqlIngestRequest",
        "message" =>
          "body must be {\"format\", \"mapping_iri\", \"data_b64\"} with string values"
      }
    })
  end

  defp run_pipeline(conn, format, mapping_iri, data_b64) do
    with {:ok, sql_text} <- decode_data(data_b64),
         {:ok, tables} <- SqlIngest.parse_dump(sql_text),
         # GLD-6: the SHACL gate rides the DATA itself (per-row, over the
         # SQLD-5 auto-shapes) — refusal precedes any projection.
         :ok <- Smalt.GraphLaw.SqlRowGate.check(sql_text, tables) do
      respond_projected(conn, format, mapping_iri, tables)
    else
      {:error, {:injection_token, name}} ->
        andon_refusal(
          conn,
          mapping_iri,
          "sql.injection_token",
          "COPY target \"#{name}\" carries SQL metacharacters",
          "table name \"#{name}\" failed the identifier guard; " <>
            "rename the table to ^[a-zA-Z_][a-zA-Z0-9_]*$ (optionally schema-qualified) " <>
            "and re-POST",
          {:injection_token, mapping_iri, name}
        )

      {:error, :unterminated_copy_block} ->
        andon_refusal(
          conn,
          mapping_iri,
          "sql.unterminated_copy_block",
          "a COPY ... FROM stdin block has no \\. terminator",
          "terminate every COPY block with a \\. line and re-POST",
          {:unterminated_copy_block, mapping_iri}
        )

      {:refusal, refusal} ->
        andon_refusal(
          conn,
          mapping_iri,
          refusal.rule_id,
          refusal.diagnostic,
          refusal.repair_hint,
          refusal.digest_term
        )

      {:error, :not_base64} ->
        send_json(conn, 400, %{
          "error" => %{
            "code" => "InvalidDataEncoding",
            "message" => "data_b64 is not valid base64"
          }
        })
    end
  end

  defp decode_data(data_b64) do
    case Base.decode64(data_b64) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, :not_base64}
    end
  end

  # -- OCEL projection ---------------------------------------------------------

  # One sql_table object + one SqlTableIngested event per ingested table, plus
  # one mapping object; every relationship points at an emitted object, so the
  # envelope satisfies Smalt.Ocel.validate_envelope/2 by construction.
  defp project(mapping_iri, tables) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    mapping_object = %{
      "id" => mapping_iri,
      "type" => "sql_mapping",
      "attributes" => %{"iri" => mapping_iri, "recordedAt" => ts}
    }

    {events, table_objects} =
      Enum.reduce(tables, [], fn {name, %{columns: columns, rows: rows}}, acc ->
        object_id = "urn:smalt:sql:#{mapping_iri}:#{name}"

        object = %{
          "id" => object_id,
          "type" => "sql_table",
          "attributes" => %{
            "name" => name,
            "columns" => columns,
            "rowCount" => length(rows),
            "mappingIri" => mapping_iri
          }
        }

        event = %{
          "id" => "evt-sql-ingest-#{object_id}-#{System.unique_integer([:positive])}",
          "type" => "SqlTableIngested",
          "time" => ts,
          "attributes" => %{"tableName" => name, "rowCount" => length(rows)},
          "relationships" => [
            %{"objectId" => mapping_iri, "qualifier" => "conformsTo"},
            %{"objectId" => object_id, "qualifier" => "derivedFrom"}
          ]
        }

        [{event, object} | acc]
      end)
      |> Enum.unzip()

    objects = [mapping_object | Enum.reverse(table_objects)]
    {Enum.reverse(events), objects}
  end

  defp respond_projected(conn, format, mapping_iri, tables) do
    {events, objects} = project(mapping_iri, tables)

    # Never answer 201 with a structurally-dangling projection.
    :ok = Ocel.validate_envelope(events, objects)

    send_json(conn, 201, %{
      "status" => "ingested",
      "format" => format,
      "mappingIri" => mapping_iri,
      "tables" =>
        Enum.map(objects -- [hd(objects)], fn obj ->
          %{
            "name" => obj["attributes"]["name"],
            "columns" => obj["attributes"]["columns"],
            "rowCount" => obj["attributes"]["rowCount"]
          }
        end),
      "ocel" => %{"eventCount" => length(events), "objectCount" => length(objects)}
    })
  end

  # -- andon refusal (GL-8 wire face) ------------------------------------------

  defp andon_refusal(conn, _mapping_iri, rule_id, diagnostic, repair_hint, digest_term) do
    receipt = %{
      rule_id: rule_id,
      diagnostic: diagnostic,
      agent_message: "SQL ingestion refused by law #{rule_id}: #{diagnostic}",
      repair_hint: repair_hint,
      context_digest: andon_digest(digest_term),
      session: to_string(node())
    }

    case AndonWire.http_envelope(receipt) do
      %{status: status, headers: headers, content_type: ct, body: body} ->
        conn
        |> reduce_headers(headers)
        |> put_resp_header("content-type", ct)
        |> send_resp(status, body)

      {:error, :unwirable_shape} ->
        # Unreachable for receipts this module constructs; fail closed loudly
        # rather than emitting a non-andon shape the consumer would trust.
        send_json(conn, 500, %{
          "error" => %{"code" => "AndonWireShapeError", "message" => "internal refusal envelope"}
        })
    end
  end

  defp andon_digest(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end

  defp reduce_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
  end
end
