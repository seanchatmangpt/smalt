defmodule Smalt.Aoq.Admission do
  @moduledoc """
  AoQ micro-batch SHACL admission (v26.11.6 WO-10, lane 9).

  Folds worker-collected frame documents into a length-prefixed fold binary
  (`<<len::32, frame::binary-size(len), ...>>`, encoded by `encode_fold/1`),
  admits the whole fold in ONE `Smalt.GraphlawEx.ShaclAdmission.admit/2`
  engine call (O(batches), not O(frames)), and on SHACL violation bisects
  the fold log2(N) to attribute the exact violating frame indices.

  ## Shared-seam contract (ONE AshGraphLaw Host, two callers)

  This module and the ARM drain-boundary admit (lane L16's surface) are TWO
  callers of the ONE `AshGraphLaw.Host`: this module starts no second engine
  runtime. It is a pure fold -> admit -> gate pipeline over the same
  `Smalt.GraphlawEx.ShaclAdmission.admit/2` seam: callers holding the Host
  pid pass it via `:engine_opts [server: pid]`; callers without a pid ride
  the default host name, same as production. The `:shacl_module` and
  `:shapes` overrides are court seams, never production defaults.

  ## Config

      config :smalt, :aoq_admission,
        enabled: true,          # default true - admission on, fail-closed
        ledger_ttl_ms: 60_000   # replay-ledger window (default 60 s)

  `enabled: false` is an explicit passthrough (the AdmissionGate opt-out
  posture): admit_batch/2 answers
  `{:ok, %{admitted: false, passthrough: true, frame_count: n}}` before any
  engine call. Fail-closed law: absent engine, unpinned digest, shapes-graph
  read failure, and SHACL violation all refuse - a missing engine never
  admits, and there is no admit-and-seal posture on the AoQ ingest path
  (the `fail_closed` flag lives only on AdmissionGate, never here).

  ## Receipt

  The batch receipt is a FRESH sha256 over (engine_digest, shape_iri,
  per-frame hash list in order) - the folded run's internal ShaclAdmission
  receipt (minted over the expanded text) is NEVER reused: one receipt per
  admitted surface, and the batch receipt pins the exact frame list that
  composed the batch, not the fold binary.
  """

  alias Smalt.GraphlawEx.{AdmissionGate, ShaclAdmission}

  @batch_max 32
  @default_ledger_ttl_ms 60_000
  @ledger_table :smalt_aoq_admission_ledger
  @shape_iri "prov:StreamFrameShape"
  @gated_method "POST"

  @doc "Maximum frames per admitted batch (micro-batch cap, 32)."
  @spec batch_max() :: 32
  def batch_max, do: @batch_max

  @doc """
  Encode frame documents as the length-prefixed fold binary
  `<<len::32, frame::binary-size(len), ...>>`.
  """
  @spec encode_fold([binary()]) :: binary()
  def encode_fold(frames) when is_list(frames) do
    for f <- frames, into: <<>>, do: <<byte_size(f)::32-unsigned-big, f::binary>>
  end

  @doc """
  Admit a list of frame documents (binaries) as ONE batch.

  Returns `{:ok, receipt}` with keys `:admitted`, `:receipt_sha256` (64-char
  lowercase hex), `:engine_digest`, `:frame_count`, `:frame_hashes`
  (per-frame sha256 hex in order), `:violating_frames` (empty list on the
  admit path) — or `{:refused, code, details}`.

  Refusal codes (append-only): `:smalt_shacl_violation` (details carry
  `violating_frames` attribution indices), plus the pass-through code sets
  of `ShaclAdmission.admit/2` (`:smalt_graphlaw_engine_absent`,
  `:smalt_graphlaw_engine_unpinned`, `:smalt_shapes_unreadable`,
  `:smalt_graphlaw_engine_error`) and `AdmissionGate.gate/3`
  (`:smalt_no_receipt`, `:smalt_payload_mismatch`, `:smalt_oversize`,
  `:smalt_receipt_invalid`, `:smalt_receipt_replay_fail`,
  `:smalt_engine_drift`).

  Refusals emit `[:smalt, :aoq, :admission, :refused]` telemetry with
  `%{count: 1}` measurements and `%{code: code, frame_count: n}` metadata.
  """
  @spec admit_batch([binary()], keyword()) :: {:ok, map()} | {:refused, atom(), map()}
  def admit_batch(frames, opts \\ [])

  def admit_batch(frames, opts) when is_list(frames) do
    cfg = Application.get_env(:smalt, :aoq_admission, [])

    if Keyword.get(cfg, :enabled, true) do
      do_admit_batch(frames, opts)
    else
      {:ok, %{admitted: false, passthrough: true, frame_count: length(frames)}}
    end
  end

  def admit_batch(frames, _opts) do
    {:refused, :smalt_aoq_batch_not_list, %{frames_class: value_class(frames)}}
  end

  ## -- internal -------------------------------------------------------------

  defp do_admit_batch(frames, opts) do
    fold = encode_fold(frames)
    shacl_opts = [shape_iri: @shape_iri, data_fold: true] ++ opts

    case ShaclAdmission.admit(fold, shacl_opts) do
      {:ok, _folded_run_receipt} ->
        # The folded run's internal receipt is never reused: the batch
        # receipt is minted fresh over (digest, shape_iri, per-frame hashes).
        digest = resolved_digest(opts)
        hashes = Enum.map(frames, &frame_hash/1)
        receipt = batch_receipt(digest, hashes)
        envelope = %{
          admitted_mutation: true,
          payload_bytes: fold,
          receipt_blake3: receipt,
          engine_digest: digest,
          ocel_frame: %{shape: @shape_iri, data_bytes: byte_size(fold)}
        }

        with :ok <- ledger_replay_check(receipt),
             :ok <- AdmissionGate.gate(@gated_method, envelope, body: fold, engine_digest: digest) do
          ledger_record(receipt)

          {:ok,
           %{
             admitted: true,
             receipt_sha256: receipt,
             engine_digest: digest,
             frame_count: length(frames),
             frame_hashes: hashes,
             violating_frames: []
           }}
        else
          {:refused, _, _} = refused -> refused_event(refused, length(frames))
        end

      {:refused, :smalt_shacl_violation, details} ->
        violating = bisect(frames, opts)
        refused = {:refused, :smalt_shacl_violation, Map.put(details, :violating_frames, violating)}
        refused_event(refused, length(frames))

      {:refused, _, _} = refused ->
        refused_event(refused, length(frames))
    end
  end

  defp resolved_digest(opts) do
    case opts[:engine_digest] || ShaclAdmission.pinned_digest() do
      nil -> ""
      d -> d
    end
  end

  defp frame_hash(frame), do: Base.encode16(:crypto.hash(:sha256, frame), case: :lower)

  defp batch_receipt(digest, hashes) do
    payload = "#{digest}|#{@shape_iri}|#{Enum.join(hashes, ",")}"
    Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  # Bisect attribution: re-admit halves on the SAME seam; a conforming half
  # prunes its subtree, a violating half recurses, a single violating frame
  # is attributed by its batch index. Worst case log2(N) engine calls per
  # violating frame; a conforming whole (already excluded by the caller)
  # would be zero.
  @spec bisect([binary()], keyword()) :: [non_neg_integer()]
  defp bisect(frames, opts), do: bisect_range(frames, 0, opts, []) |> Enum.sort()

  defp bisect_range([], _base, _opts, acc), do: acc

  defp bisect_range(frames, base, opts, acc) do
    case ShaclAdmission.admit(encode_fold(frames), [shape_iri: @shape_iri, data_fold: true] ++ opts) do
      {:ok, _} ->
        acc

      {:refused, :smalt_shacl_violation, _} ->
        case frames do
          [one] ->
            [{base, one} | acc]

          frames ->
            {left, right} = Enum.split(frames, div(length(frames), 2))
            acc1 = bisect_range(left, base, opts, acc)
            bisect_range(right, base + length(left), opts, acc1)
        end

      {:refused, _, _} = refused ->
        raise ArgumentError, "bisect hit non-violation refusal: " <> inspect(refused)
    end
  end

  ## -- replay ledger (windowed ETS, TTL-bounded -- never an unbounded MapSet)

  defp ledger_replay_check(receipt) do
    table = ledger_table()

    case :ets.lookup(table, receipt) do
      [] -> :ok
      [{_receipt, inserted_at}] ->
        if stale?(inserted_at) do
          :ets.delete(table, receipt)
          :ok
        else
          {:refused, :smalt_receipt_replay_fail, %{receipt_blake3: receipt}}
        end
    end
  end

  defp ledger_record(receipt) do
    :ets.insert(ledger_table(), {receipt, System.system_time(:millisecond)})
  end

  defp ledger_table do
    case :ets.whereis(@ledger_table) do
      :undefined ->
        try do
          :ets.new(@ledger_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @ledger_table
        end

      tid when is_reference(tid) ->
        tid
    end
  end

  # Windowed ledger: prune expired entries (select_delete on insert path is
  # O(table); the table only ever holds receipts seen inside the TTL window,
  # so it is bounded by throughput x ttl, never unbounded).
  defp stale?(inserted_at) do
    System.system_time(:millisecond) - inserted_at > ledger_ttl_ms()
  end

  defp ledger_ttl_ms do
    cfg = Application.get_env(:smalt, :aoq_admission, [])
    ttl = Keyword.get(cfg, :ledger_ttl_ms, @default_ledger_ttl_ms)

    case ttl do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_ledger_ttl_ms
    end
  end

  ## -- telemetry ------------------------------------------------------------

  @spec refused_event({:refused, atom(), map()}, non_neg_integer()) ::
          {:refused, atom(), map()}
  defp refused_event({:refused, code, _details} = refused, frame_count) do
    :telemetry.execute(
      [:smalt, :aoq, :admission, :refused],
      %{count: 1},
      %{code: code, frame_count: frame_count}
    )

    refused
  end


  defp value_class(nil), do: :nil
  defp value_class(v) when is_binary(v), do: :binary
  defp value_class(v) when is_integer(v), do: :integer
  defp value_class(_other), do: :other
end
