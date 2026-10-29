defmodule Smalt.ConfidentialLedger.Service do
  @moduledoc """
  AZ-3 — Azure Confidential Ledger REST face **over the landed journal
  substrate** (`.wal`-class frames + SJ-1 seal ladder + SJ-2 fail-closed
  reader + the sha256-chain of `Smalt.Sync.Receipt` + the VC 2.0 export of
  `Smalt.Receipt.VcExport`).

  Reference: Azure Confidential Ledger REST — `POST /app/transactions`
  appends `{"contents": ...}` and answers `201 {"transactionId": "N.M"}`;
  the entry is PENDING until the consensus service certifies it, then
  Committed; `GET /app/transactions/{transactionId}?api-version=` returns
  `{"entry": {"contents", "transactionId"}, "state": "Committed"|"PENDING"}`;
  `GET /app/transactions/{transactionId}/receipt` returns the CCF-style
  receipt (`leaf` / `root` / `proof`); `GET /app/transactions` lists by
  `rangeBegin`/`rangeEnd` (`nextRangeLink` when a page is truncated).

  # KD-COVERS: KD-170 (Confidential Ledger receipt face; renumbered from
  # KD-166 — dual-claim fold, KD-166 is the Web PubSub WS handshake row)

  Mapping onto the landed substrate (the face is served by
  `Smalt.ConfidentialLedger.Router` on its own port — on 8443 `/app/*`
  remains the pre-existing ETS-ledger face):

  | ACL concept       | Landed substrate                                                                       |
  |-------------------|----------------------------------------------------------------------------------------|
  | append            | `Smalt.Storage.JournalSink.append/6` frame append                                       |
  | certification     | the SJ-1 seal ladder (`do_seal/1` rename triple) + the sha256-chain root recomputed over the sealed segment by the SJ-2 reader |
  | receipt           | `Smalt.Sync.Receipt.mint/1` 320-byte token exposed as ACL JSON (`leaf`/`root`/`proof`)  |
  | certificate       | `Smalt.Receipt.VcExport.to_vc/2` over the same 320-byte token (VC 2.0)                  |
  | transactionId     | `"<seq>.1"` from the sink's monotonic SeqID                                             |
  | PENDING→Committed | frame in an open (unsealed) segment → Pending; seal + certified root → Committed        |

  Typed laws carried over from the substrate:

  * integrity (tampered sealed segment) → typed refusal, never a partial
    admission (SJ-2 law);
  * completeness (crash-window / quarantined segment, BK-54 class) → the
    transaction stays Pending — never silently committed (SPOF-A3 law);
  * a degraded sink answers `{:error, :ledger_degraded}` and records NO
    transaction — accepted-and-dropped must never read as an admission
    (A-1 law).
  """

  use GenServer

  alias Smalt.Receipt.VcExport
  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink
  alias Smalt.Sync.Receipt

  @certify_interval_ms 2_000

  ## -- client API -------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## -- client API ---------------------------------------------------------------

  @doc """
  Appends `contents` (a JSON-encodable term) as one journal frame. Returns
  `{:ok, tx_id}` (`"N.1"`) or `{:error, :ledger_degraded}` — a degraded sink
  records no transaction (never silently committed).
  """
  @spec append(term()) :: {:ok, String.t()} | {:error, :ledger_degraded}
  def append(contents) do
    GenServer.call(__MODULE__, {:append, contents})
  end

  @doc """
  Forces one certification pass (the seal-ladder read). Exposed for courts
  and for callers that must not wait for the tick.
  """
  @spec certify() :: :ok
  def certify, do: GenServer.call(__MODULE__, :certify)

  @doc """
  `{:ok, %{"transactionId" => id, "contents" => contents, "state" => "Committed" | "Pending"}}`,
  `{:error, :not_found}`, or `{:error, {:integrity, detail}}` when the
  segment certifying the tx fails the fail-closed re-read.
  """
  @spec transaction(String.t()) ::
          {:ok, map()} | {:error, :not_found} | {:error, {:integrity, term()}}
  def transaction(tx_id), do: GenServer.call(__MODULE__, {:transaction, tx_id})

  @doc """
  The ACL JSON receipt for `tx_id`:

      %{
        "transactionId" => id, "state" => "Committed",
        "receipt" => %{"leaf" => hex, "root" => hex, "nodeId" => id,
                       "proof" => [%{"leaf" => hex}, ...],
                       "leafCount" => n, "segment" => seg,
                       "firstSeq" => f, "lastSeq" => l,
                       "receiptToken" => 640-hex}
      }

  `proof` is the full transparency witness: the segment's leaves in chain
  order; a verifier refolds them with the `Smalt.Sync.Receipt` algebra and
  compares `root` (KD-166). Re-verifies the segment bytes at read time — a
  tampered sealed segment is a typed `{:error, {:integrity, detail}}`, never
  a stale pass (SJ-2 law).
  """
  @spec receipt(String.t()) ::
          {:ok, map()}
          | {:error, :not_found}
          | {:error, :not_certified}
          | {:error, {:integrity, term()}}
  def receipt(tx_id), do: GenServer.call(__MODULE__, {:receipt, tx_id})

  @doc "The VC 2.0 export of the receipt (the certificate endpoint variant)."
  @spec certificate(String.t()) ::
          {:ok, map()} | {:error, :not_found} | {:error, :not_certified} | {:error, term()}
  def certificate(tx_id) do
    with {:ok, r} <- receipt(tx_id),
         token = r["receipt"]["receiptToken"],
         first = r["receipt"]["firstSeq"],
         last = r["receipt"]["lastSeq"] do
      {:ok,
       VcExport.to_vc(token,
         issuer: issuer(),
         seq_horizon: {first, last},
         id: "urn:smalt:acl:tx:#{tx_id}"
       )}
    end
  end

  @doc """
  Range list over transactions. `range_begin`/`range_end` are transactionId
  strings (`"N.1"`); `nil` = unbounded on that side. Returns
  `%{"transactions" => [...], "nextRangeLink" => string | nil}`.
  """
  @spec transactions(String.t() | nil, String.t() | nil, non_neg_integer()) ::
          {:ok, map()} | {:error, {:integrity, term()}} | {:error, :invalid_range}
  def transactions(range_begin, range_end, limit \\ 100) do
    case valid_range(range_begin, range_end) do
      :ok -> GenServer.call(__MODULE__, {:transactions, range_begin, range_end, limit})
      {:error, _} = err -> err
    end
  end

  @doc """
  EXPL-11 F1: `rangeBegin`/`rangeEnd` are transactionId strings and must be
  `N.M` with non-negative integer `N` and `M` (real ACL validates them as
  transactionIds). A malformed range is a typed refusal at the boundary —
  never a silent coercion to seq 0 (range widened to all) and never a
  `binary_to_integer` crash inside `handle_call` (remote DoS). Pure, so the
  router can refuse before the GenServer is touched.
  """
  @spec valid_range(String.t() | nil, String.t() | nil) :: :ok | {:error, :invalid_range}
  def valid_range(rb, re) do
    if valid_tx_id?(rb) and valid_tx_id?(re), do: :ok, else: {:error, :invalid_range}
  end

  @spec valid_tx_id?(term()) :: boolean()
  def valid_tx_id?(nil), do: true

  def valid_tx_id?(id) when is_binary(id) do
    case String.split(id, ".", parts: 2) do
      [seq, sub] -> digits?(seq) and digits?(sub)
      _ -> false
    end
  end

  def valid_tx_id?(_), do: false

  defp digits?(s), do: s != "" and Regex.match?(~r/^\d+$/, s)

  ## -- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Path.expand(Keyword.fetch!(opts, :dir))
    sink = Keyword.get(opts, :sink, JournalSink)
    interval = Keyword.get(opts, :certify_interval_ms, @certify_interval_ms)
    if interval > 0, do: Process.send_after(self(), :certify_tick, interval)

    {:ok,
     %{
       dir: dir,
       sink: sink,
       interval: interval,
       issuer: Keyword.get(opts, :issuer, "urn:smalt:acl:default_ledger"),
       # tx_id => %{seq, contents, state: :pending | {:committed, seg_name}}
       txs: %{},
       # seg_name => %{status: :committed | :refused, ...}
       segs: %{}
     }}
  end

  @impl true
  def handle_info(:certify_tick, state) do
    state = run_certify(state)
    if state.interval > 0, do: Process.send_after(self(), :certify_tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call({:append, contents}, _from, state) do
    case sink_mode(state.sink) do
      :active ->
        payload = Jason.encode!(contents)

        case JournalSink.append(state.sink, 1, 0, "acl", payload) do
          {:ok, seq} ->
            tx_id = "#{seq}.1"

            {:reply, {:ok, tx_id},
             %{state | txs: Map.put(state.txs, tx_id, %{seq: seq, contents: contents, state: :pending})}}

          {:error, _} ->
            {:reply, {:error, :ledger_degraded}, state}
        end

      :degraded ->
        {:reply, {:error, :ledger_degraded}, state}
    end
  end

  def handle_call(:certify, _from, state) do
    {:reply, :ok, run_certify(state)}
  end

  def handle_call({:transaction, tx_id}, _from, state) do
    {:reply, lookup(state, tx_id), state}
  end

  def handle_call({:receipt, tx_id}, _from, state) do
    {:reply, receipt_for(state, tx_id), state}
  end

  def handle_call({:transactions, rb, re, limit}, _from, state) do
    {:reply, list(state, rb, re, limit), state}
  end

  ## -- internals --------------------------------------------------------------

  defp sink_mode(sink) do
    case sink_status(sink) do
      {:ok, %{mode: :active}} -> :active
      _ -> :degraded
    end
  end

  defp sink_status(sink) do
    try do
      {:ok, JournalSink.status(sink)}
    rescue
      ArgumentError -> :error
    catch
      :exit, _ -> :error
    end
  end

  # A certification pass over the current sealed segments. Already-certified
  # segments keep their certification (integrity re-verification happens at
  # receipt-read time, fail-closed per read); newly sealed segments are read
  # by the SJ-2 reader and folded into the sha256-chain.
  defp run_certify(state) do
    maybe_seal(state.sink)
    {:ok, segs} = JournalReader.discover_sealed_segments(state.dir)

    segs =
      Enum.reduce(segs, state.segs, fn seg_path, acc ->
        name = Path.basename(seg_path)

        case Map.get(acc, name) do
          %{status: :committed} -> acc
          _ -> Map.put(acc, name, certify_segment(seg_path, Map.get(acc, name)))
        end
      end)

    # flip pending txs covered by a certified segment
    txs =
      Map.new(state.txs, fn {tx_id, tx} ->
        case tx do
          %{state: :pending, seq: seq} ->
            case committing_seg(segs, seq) do
              %{status: :committed} = rec -> {tx_id, %{tx | state: {:committed, rec.name}}}
              _ -> {tx_id, tx}
            end

          committed_tx ->
            {tx_id, committed_tx}
        end
      end)

    %{state | segs: segs, txs: txs}
  end

  defp certify_segment(seg_path, prior) do
    name = Path.basename(seg_path)

    # EXPL-11 F5: meta is load-bearing here — a committed record feeds
    # first_seq/last_seq into committing_seg/2 comparisons. A missing or
    # corrupt meta must refuse typed (matching JournalReader's
    # {:missing_meta, path} idiom), never launder into nil comparisons.
    # An empty sealed segment still certifies nothing (no leaves, no root) —
    # never mint a receipt over zero frames.
    case seg_meta(seg_path) do
      {:ok, %{"frames" => f, "first_seq" => fs, "last_seq" => ls}}
      when is_integer(f) and f > 0 and is_integer(fs) and is_integer(ls) ->
        case JournalReader.read_sealed_segment(seg_path) do
          {:ok, frames} ->
            # sequential fold: the receipt algebra chains prev_root <> leaf
            {chain, leaves} =
              Enum.reduce(frames, {Receipt.empty_chain(), %{}}, fn f, {chain, leaves} ->
                wire = frame_wire(f)
                leaf = :crypto.hash(:sha256, wire)

                {Receipt.absorb(chain, wire),
                 Map.put(leaves, f.seq_id, Base.encode16(leaf, case: :lower))}
              end)

            %{
              status: :committed,
              name: name,
              seg_path: seg_path,
              receipt_token: Receipt.mint(chain),
              root_hex:
                (chain.root && Base.encode16(chain.root, case: :lower)) || String.duplicate("0", 64),
              leaf_count: chain.count,
              first_seq: fs,
              last_seq: ls,
              leaves: leaves
            }

          {:error, reason} ->
            refuse_segment(prior, name, seg_path, reason)
        end

      {:ok, %{"frames" => f}} when is_integer(f) and f > 0 ->
        # frame-bearing segment with missing/untyped seq bounds — the
        # certify-tick nil-compare crash class; refuse typed, fail-closed
        refuse_segment(prior, name, seg_path, :corrupt_meta)

      {:ok, _} ->
        refuse_segment(prior, name, seg_path, :empty_segment)

      {:error, reason} ->
        refuse_segment(prior, name, seg_path, reason)
    end
  end

  defp refuse_segment(prior, name, seg_path, reason) do
    Map.merge(prior || %{}, %{status: :refused, name: name, seg_path: seg_path, reason: reason})
  end

  defp maybe_seal(sink) do
    with {:ok, %{frames: frames}} <- sink_status(sink),
         true <- frames > 0,
         %{} <- JournalSink.seal(sink) do
      :ok
    else
      _ -> :ok
    end
  end


  defp frame_wire(f),
    do: elem(JournalSink.encode_frame(f.seq_id, f.ts, f.event_type, f.table_id, f.key, f.payload), 0)

  defp seg_meta(seg_path) do
    case File.read(seg_path <> ".meta.json") do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, meta} when is_map(meta) -> {:ok, meta}
          _ -> {:error, :corrupt_meta}
        end

      {:error, _} ->
        {:error, :missing_meta}
    end
  end

  defp committing_seg(segs, seq) do
    Enum.find(segs, fn {_name, rec} ->
      rec.status == :committed and seq >= rec.first_seq and seq <= rec.last_seq
    end)
    |> case do
      {_name, rec} -> rec
      nil -> nil
    end
  end

  defp lookup(state, tx_id) do
    case Map.get(state.txs, tx_id) do
      nil ->
        {:error, :not_found}

      %{state: :pending} = tx ->
        {:ok, %{"transactionId" => tx_id, "contents" => tx.contents, "state" => "Pending"}}

      %{state: {:committed, seg}} = tx ->
        case reverify_segment(state, seg) do
          :ok ->
            {:ok, %{"transactionId" => tx_id, "contents" => tx.contents, "state" => "Committed"}}

          {:error, reason} ->
            {:error, {:integrity, reason}}
        end
    end
  end

  defp receipt_for(state, tx_id) do
    case Map.get(state.txs, tx_id) do
      nil ->
        {:error, :not_found}

      %{state: :pending} ->
        {:error, :not_certified}

      %{state: {:committed, seg}} ->
        case Map.get(state.segs, seg) do
          %{status: :committed} = rec ->
            tx = state.txs[tx_id]

            case reverify_segment(state, seg) do
              :ok ->
                {:ok,
                 %{
                   "transactionId" => tx_id,
                   "state" => "Committed",
                   "receipt" => %{
                     "leaf" => rec.leaves[tx.seq],
                     "root" => rec.root_hex,
                     "nodeId" => state.issuer,
                     "proof" =>
                       rec.leaves
                       |> Enum.sort_by(fn {seq, _leaf} -> seq end)
                       |> Enum.map(fn {_seq, leaf} -> %{"leaf" => leaf} end),
                     "leafCount" => rec.leaf_count,
                     "segment" => rec.name,
                     "firstSeq" => rec.first_seq,
                     "lastSeq" => rec.last_seq,
                     "receiptToken" => rec.receipt_token
                   }
                 }}

              {:error, reason} ->
                {:error, {:integrity, reason}}
            end

          _ ->
            {:error, :not_certified}
        end
    end
  end

  defp list(state, rb, re, limit) do
    tx_ids =
      state.txs
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.sort_by(fn id -> seq_of(id) end)

    in_range = Enum.filter(tx_ids, fn id -> in_range?(id, rb, re) end)
    page = Enum.take(in_range, limit)

    case integrity_errors(state, page) do
      [] ->
        next =
          if length(in_range) > limit and page != [] do
            "/app/transactions?api-version=2022-05-17&rangeBegin=#{List.last(page)}"
          else
            nil
          end

        {:ok,
         %{
           "transactions" =>
             Enum.map(page, fn id ->
               case lookup(state, id) do
                 {:ok, t} -> t
                 _ -> nil
               end
             end)
             |> Enum.reject(&is_nil/1),
           "nextRangeLink" => next
         }}

      [reason | _] ->
        {:error, {:integrity, reason}}
    end
  end

  defp integrity_errors(state, tx_ids) do
    Enum.flat_map(tx_ids, fn id ->
      case Map.get(state.txs, id) do
        %{state: {:committed, seg}} ->
          case reverify_segment(state, seg) do
            :ok -> []
            {:error, reason} -> [reason]
          end

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  # Fail-closed per read: the certified state is trusted only while the
  # sealed segment still passes the SJ-2 reader (manifest sha256 + per-frame
  # CRC + monotonic seq). A tampered byte is a typed refusal, never a stale
  # pass.
  defp reverify_segment(state, seg) do
    case Map.get(state.segs, seg) do
      %{status: :committed, seg_path: path} ->
        case JournalReader.read_sealed_segment(path) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:segment, seg, reason}}
        end

      %{status: :refused, reason: reason} ->
        {:error, {:segment, seg, reason}}

      nil ->
        {:error, {:segment, seg, :not_certified}}
    end
  end

  defp in_range?(id, rb, re) do
    seq = seq_of(id)

    (is_nil(rb) or seq >= seq_of(rb)) and (is_nil(re) or seq <= seq_of(re))
  end

  defp seq_of(id) do
    case String.split(id, ".", parts: 2) do
      [seq, _] -> String.to_integer(seq)
      _ -> 0
    end
  end

  defp issuer, do: "urn:smalt:acl:default_ledger"
end
