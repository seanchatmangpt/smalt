defmodule Smalt.ArmGateway.ResourceGraph do
  @moduledoc """
  ARM-gateway-facing handler for `POST /providers/Microsoft.ResourceGraph/resources`.

  Query-gate law (mirrors the cosmos SQL whitelist, cosmos.ex `@sql_whitelist`):
  only the supported KQL-subset clauses parse — `where`, `project`, `order by`,
  `sort by`, `take`/`limit` (limit/top), `summarize` (count() aggregate),
  `extend` — anything else is a typed 400 naming the offending clause, never a
  silent wrong answer and never a crash-path 500:

      {:error, 400, %{"error" => %{"code" => "UnsupportedClause",
        "message" => "pipeline clause 'mv-expand' is not supported; supported clauses: ..."}}}

  Evaluation, envelope (`totalRecords`/`count`/`data`/`facets`/`$skipToken`),
  facets, resultFormat and skip-token pagination are delegated to
  `Smalt.DataPlane.ResourceGraph` (the single evaluator over `Store`
  `:smalt_resources`); this module is the arm_gateway seam: the envelope-shape
  gate (api-version, body, clause whitelist) in front of the one evaluator, so
  clause support is declared at the gateway seam exactly once.

  Route wiring: the router's existing `POST /providers/Microsoft.ResourceGraph/resources`
  handler (GAP-AZB20-6) carries the identical contract inline; adopting this
  module as the handler body is a router-file change owned by the coordinator
  (router.ex is outside this lane's lease).
  """

  alias Smalt.DataPlane.ResourceGraph

  @api_version "2022-10-01"
  # The supported clause set. `limit N` is a `take N` synonym in real Kusto and
  # is admitted under the same clause; `extend` is carried by the underlying
  # evaluator and admitted to keep the gate and the evaluator verdict-identical
  # (a stricter gateway gate would diverge from the wired route's behavior).
  @supported_clauses MapSet.new(~w(where project order sort take limit summarize extend))

  # Clause keywords the gate recognizes as CLAUSES (and therefore refuses when
  # unsupported). A single unpiped stage whose leading word is NOT here is a
  # bare table reference, not a clause.
  @known_unsupported_clauses ~w(mv-expand mvexpand invoke render distinct as union join project-away projectaway)

  @doc """
  Handles a Resource Graph query envelope: `query(body, api_version)` ->
  `{:ok, 200, envelope}` | `{:error, status, error_env}`.

  Gate order: api-version -> body shape -> clause whitelist -> evaluator
  (subscription filter, KQL pipeline, facets, pagination).
  """
  @spec query(term(), term()) :: {:ok, 200, map()} | {:error, pos_integer(), map()}
  def query(body, api_version)

  def query(body, @api_version) do
    body = if is_map(body), do: body, else: %{}

    with :ok <- clause_gate(Map.get(body, "query")),
         {:ok, 200, resp} <-
           ResourceGraph.query(Map.get(body, "subscriptions"), body, @api_version) do
      {:ok, 200, resp}
    end
  end

  # api-version gate: reuses the evaluator's typed InvalidApiVersion envelope
  # (identical code/message to what the evaluator emits directly).
  def query(body, _other), do: ResourceGraph.query(nil, body, "wrong")

  # -- Clause whitelist gate ---------------------------------------------------

  # nil/empty query = unfiltered table scan (all clauses absent) — admitted.
  defp clause_gate(nil), do: :ok
  defp clause_gate(""), do: :ok

  defp clause_gate(query) when is_binary(query) do
    case stage_leading_words(query) do
      {:ok, words} ->
        # Mirror the evaluator's table-reference law (data_plane
        # resource_graph.ex normalize_pipeline/1): in a NON-pipe-led piped
        # query, a leading word that is neither a supported clause nor a
        # known-unsupported clause is a bare table reference
        # ("Resources | project name") — dropped, not refused. Refusing it
        # would reject every piped query spelled with its table name, the
        # portal search bar's exact shape. Pipe-led queries stay strict on
        # every stage (an unknown first-stage operator is the evaluator's
        # typed BadQuery, pinned by the frobnicate test).
        words =
          if String.starts_with?(String.trim_leading(query), "|") do
            words
          else
            case words do
              [first | rest] ->
                if MapSet.member?(@supported_clauses, first) or
                     first in @known_unsupported_clauses do
                  [first | rest]
                else
                  rest
                end

              [] ->
                []
            end
          end

        case Enum.reject(words, &MapSet.member?(@supported_clauses, &1)) do
          [] -> :ok
          [bad | _] -> {:error, 400, unsupported_clause_error(bad)}
        end

      {:error, msg} ->
        {:error, 400,
         %{"error" => %{"code" => "BadQuery", "message" => "Invalid query: " <> msg}}}
    end
  end

  # A non-string query field is not a clause violation — the evaluator owns
  # that surface (it ignores non-binary queries); the gate stays in its lane.
  defp clause_gate(_), do: :ok

  defp unsupported_clause_error(clause) do
    supported =
      @supported_clauses
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.join(", ")

    %{
      "error" => %{
        "code" => "UnsupportedClause",
        "message" =>
          "pipeline clause '#{clause}' is not supported; supported clauses: #{supported}"
      }
    }
  end

  # Extracts the leading word of each pipeline stage, respecting quoted string
  # literals ('...' and "...") so a `|` inside a literal does not split stages.
  # Returns {:ok, [word]} (empty list for a bare table reference like
  # "Resources") or {:error, msg} for an unterminated literal.
  defp stage_leading_words(query) do
    case split_stages_outside_quotes(query) do
      {:error, msg} ->
        {:error, msg}

      {:ok, stages} ->
        # A single stage with no pipe whose leading word is not a clause
        # keyword at all is a bare table reference ("Resources") — the
        # evaluator admits it as an unfiltered scan; the gate stays
        # verdict-identical and admits it too.
        words =
          stages
          |> Enum.flat_map(fn stage ->
            case String.trim(stage) do
              "" -> []
              trimmed -> [trimmed |> first_word() |> normalize_limit()]
            end
          end)
          |> Enum.reject(&(&1 == ""))

        if length(stages) == 1 and not String.contains?(query, "|") do
          case words do
            [only] ->
              if only in @known_unsupported_clauses do
                {:ok, words}
              else
                {:ok, []}
              end

            _ ->
              {:ok, words}
          end
        else
          {:ok, words}
        end
    end
  end

  # `limit` and `take` are the same clause (Kusto synonyms); the gate reads
  # `limit` under its `take` admission. All clause words downcase (real KQL
  # clause keywords are case-insensitive).
  defp normalize_limit("limit"), do: "take"
  defp normalize_limit(w), do: String.downcase(w)

  defp first_word(stage) do
    stage
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  # Splits on `|` occurring outside single/double quotes; an unterminated
  # literal is a gate error (the evaluator's lexer would also refuse it).
  defp split_stages_outside_quotes(q), do: scan(q, <<>>, [], nil)

  defp scan(<<>>, cur, acc, quote_char) do
    if quote_char do
      {:error, "unterminated string literal"}
    else
      {:ok, Enum.reverse([cur | acc])}
    end
  end

  defp scan(<<q, rest::binary>>, cur, acc, quote_char) when q == ?' or q == ?" do
    if quote_char == q do
      scan(rest, <<cur::binary, q>>, acc, nil)
    else
      scan(rest, <<cur::binary, q>>, acc, q)
    end
  end

  defp scan(<<?|, rest::binary>>, cur, acc, nil),
    do: scan(rest, <<>>, [cur | acc], nil)

  defp scan(<<c, rest::binary>>, cur, acc, quote_char),
    do: scan(rest, <<cur::binary, c>>, acc, quote_char)
end
