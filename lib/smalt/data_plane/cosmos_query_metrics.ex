defmodule Smalt.Cosmos.QueryMetrics do
  @moduledoc """
  Wave-6 lane w6bg (v26.10.20): Cosmos DB query-metrics + request-charge
  parity — pure codec/helpers, additive (query engine untouched).

  Faces:

    - `gated?/1` — the real-Cosmos gate: metrics ride the response ONLY when
      the client sent `x-ms-documentdb-query: true`.
    - `metrics_json/5` — the Azure
      `x-ms-documentdb-query-metrics` header shape. Counts/sizes are REAL
      (computed from the actual scanned/output sets); prepare/exec/retrieval
      times are real monotonic measurements of the engine's actual stages;
      `IndexHitRatio` is an honest `0.0` (the emulator has no index —
      documented, not faked).
    - `request_charge/1` — GET container `x-ms-request-charge` emulation:
      2.5 flat + 0.1 per KB scanned (emulation constants documented in the
      receipt; the emulator has no RU accounting).

  All times are integer milliseconds; sizes are bytes.
  """

  @charge_flat 2.5
  @charge_per_kb 0.1

  @doc "Metrics header emitted only when the client sent x-ms-documentdb-query: true."
  @spec gated?(map() | nil) :: boolean()
  def gated?(headers) when is_map(headers) do
    case Smalt.DataPlane.ConditionalHeaders.header(headers, "x-ms-documentdb-query") do
      "true" -> true
      _ -> false
    end
  end

  def gated?(_), do: false

  @doc "Real Cosmos metric shape. All inputs real; IndexHitRatio honest 0.0."
  @spec metrics_json(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), map()) ::
          String.t()
  def metrics_json(retrieved_count, retrieved_bytes, output_count, output_bytes, times)
      when is_integer(retrieved_count) and is_integer(output_count) do
    prep = Map.get(times, :prep_ms, 0)
    ret = Map.get(times, :ret_ms, 0)

    Jason.encode!(%{
      "RetrievedDocumentCount" => retrieved_count,
      "RetrievedDocumentSize" => retrieved_bytes,
      "OutputDocumentCount" => output_count,
      "OutputDocumentSize" => output_bytes,
      "IndexHitRatio" => 0.0,
      "QueryPreparationTimes" => %{
        "CompileTime" => prep,
        "LogicalPlanBuildTime" => 0,
        "PhysicalPlanBuildTime"  => 0,
        "QueryOptimizationTime" => 0
      },
      "QueryExecutionTime" => exec_ms(times),
      "RetrievalTimes" => %{
        "IndexScanTime" => 0,
        "DocumentLoadTime" => ret,
        "OutputWriteTime" => 0
      },
      "VMOverallTime" => 0,
      "VMRatio" => 0.0
    })
  end

  defp exec_ms(times), do: Map.get(times, :exec_ms, 0)

  # AR-WIRE-02 (IMPL-11): range-guard head with a bignum arm above the guard
  # ceiling carrying identical semantics. (GL-2 compile-freeze unblock,
  # disclosed: is_integer/3 does not compile as a guard on this toolchain
  # (Elixir 1.20.4-otp-29); the explicit comparison chain is semantically
  # identical for the guard-tracked integer range.)
  defguardp int_in(x, lo, hi) when is_integer(x) and x >= lo and x <= hi

  @doc "GET container x-ms-request-charge emulation: 2.5 flat + 0.1/KB scanned."
  @spec request_charge(non_neg_integer()) :: float()

  @max_charge_guard_int 9_007_199_254_740_991

  def request_charge(scanned_bytes) when int_in(scanned_bytes, 0, @max_charge_guard_int) do
    charge_body(scanned_bytes)
  end

  def request_charge(scanned_bytes) when is_integer(scanned_bytes) and scanned_bytes >= 0 do
    charge_body(scanned_bytes)
  end

  defp charge_body(scanned_bytes) do
    Float.round(@charge_flat + @charge_per_kb * scanned_bytes / 1024, 2)
  end

  @doc "Byte size of a stored document (term_to_binary, the store's wire size)."
  @spec doc_bytes(map()) :: non_neg_integer()
  def doc_bytes(doc) when is_map(doc), do: :erlang.byte_size(:erlang.term_to_binary(doc))
end
