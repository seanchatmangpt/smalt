defmodule Smalt.Security.LedgerWriter do
  @moduledoc """
  Single serialized writer for the Confidential Ledger Merkle chain.

  The append path (prev-root read -> seq increment -> receipt build + sign ->
  transaction/meta insert) must be one critical section: previously
  `latest_root/1` was read outside the seq increment, so
  two concurrent appends could both chain off the same `prev_hash` and fork
  the ledger. A single named GenServer makes the whole append atomic per
  ledger (in fact globally serialized).

  Started lazily on first append (unlinked, so a short-lived request process
  exiting cannot take the writer down); the name registration race resolves
  with exactly one writer.

  ## Chain generations (v26.11.6 BLAKE3 retarget)

  New appends are chain generation 2: the Merkle link digest is
  `BLAKE3(domain || raw32(prev_root) || seq::u64-BE || raw32(data_hash) ||
  sub_ledger_id)` with domain `SMALT/AOQ-LINK/v2` (see `link_digest/4`).
  Unlike the legacy gen-1 sha256 hex-fold, the gen-2 link binds the sequence
  number and the sub-ledger id into the digest itself, so reordering links
  or transplanting them across ledgers breaks re-derivation. `data_hash`
  stays sha256 (link-only retarget). Receipts carry `"chain_gen" => 2`
  inside the signed payload; `verify_receipt/1` dispatches on it and gen-1
  receipts verify forever under `legacy_link/2`. Golden vectors shared with
  the posh Go twin live in `verification/chain_link_vectors.json`.

  Stage 2 (Sync.Receipt journal face / `Smalt.Security.ConfidentialLedger`
  service fold onto this writer) is deliberately OUT OF SCOPE here; this
  module only owns the append-path link law.
  """

  use GenServer

  require Logger

  alias Smalt.Posh.Blake3
  alias Smalt.Security.ReceiptSigner
  alias Smalt.Store

  @link_domain "SMALT/AOQ-LINK/v2"
  @chain_gen 2
  @zero_hash String.duplicate("0", 64)
  @call_timeout 30_000

  @doc """
  Appends `contents` to `ledger` atomically. Returns `{:ok, receipt}` or a
  typed error envelope `{:error, status, %{"error" => %{"code" => code,
  "message" => message}}}` (SHIM-COURT R143-era convention: the envelope is
  wire-ready so the egress router renders it directly).
  """

  @doc """
  Chain-generation-2 Merkle link digest (lowercase hex, 64 chars):

      BLAKE3(domain_utf8 || raw32(prev_root) || seq::u64-big-endian ||
             raw32(data_hash) || sub_ledger_id)

  with `@link_domain "SMALT/AOQ-LINK/v2"`. `prev_root` and `data_hash` enter
  as RAW 32-byte decodes of their lowercase-hex wire forms (folding the hex
  TEXT instead is the canonical mutant class — killed by the shared
  golden-vector encoding-spec assertions in
  `test/smalt/security/ledger_writer_blake3_test.exs` and
  `posh/internal/receipt/chain_link_test.go`). Byte-exact with the posh Go
  twin over `verification/chain_link_vectors.json`.
  """
  @spec link_digest(String.t(), pos_integer(), String.t(), String.t()) ::
          String.t()
  def link_digest(prev_root, seq, data_hash, sub_ledger_id)
      when is_binary(prev_root) and is_integer(seq) and seq > 0 and
             is_binary(data_hash) and is_binary(sub_ledger_id) do
    <<prev_raw::binary-32>> = Base.decode16!(prev_root, case: :mixed)
    <<dh_raw::binary-32>> = Base.decode16!(data_hash, case: :mixed)

    Blake3.digest_prefixed(
      @link_domain <>
        prev_raw <>
        <<seq::unsigned-big-integer-size(64)>> <>
        dh_raw <>
        sub_ledger_id
    )
    |> Base.encode16(case: :lower)
  end

  @doc """
  Legacy chain-generation-1 link: sha256 over the hex-text fold
  `prev_root <> data_hash` (lowercase hex in, lowercase hex out). Kept
  forever for gen-1 receipt verification (`verify_receipt/1` dispatch) and
  for the seam-continuity law: a gen-2 append chains off the raw-decoded
  legacy root of the last gen-1 receipt.
  """
  @spec legacy_link(String.t(), String.t()) :: String.t()
  def legacy_link(prev_hash, data_hash)
      when is_binary(prev_hash) and is_binary(data_hash) do
    hash(prev_hash <> data_hash)
  end

  @doc """
  Verifies a ledger receipt's link integrity, dispatching on
  `receipt["chain_gen"]` (default 1 for pre-retarget receipts, which verify
  forever). Checks `data_hash` against `contents` when contents are present,
  then re-derives the Merkle link under the receipt's own generation law and
  compares to `merkle_root`. Returns `:ok` or `{:error, reason}`.
  """
  @spec verify_receipt(map()) :: :ok | {:error, term()}
  def verify_receipt(%{"merkle_root" => root} = receipt)
      when is_binary(root) do
    prev = Map.get(receipt, "prev_hash", @zero_hash)
    dh = Map.get(receipt, "data_hash")
    ledger = Map.get(receipt, "subLedgerId", "")
    gen = Map.get(receipt, "chain_gen", 1)

    with :ok <- verify_data_hash(receipt, dh),
         :ok <- verify_link(gen, prev, seq_of(receipt), dh, ledger, root) do
      :ok
    end
  end

  def verify_receipt(other), do: {:error, {:malformed_receipt, other}}

  defp verify_data_hash(_receipt, nil), do: :ok

  defp verify_data_hash(%{"contents" => contents}, dh)
       when is_map(contents) do
    case encode_contents(contents) do
      {:ok, ^dh} -> :ok
      {:ok, other} -> {:error, {:data_hash_mismatch, expected: other, got: dh}}
      :error -> {:error, {:contents_not_canonicalizable, contents}}
    end
  end

  defp verify_data_hash(_receipt, _dh), do: :ok

  defp verify_link(2, prev, seq, dh, ledger, root)
       when seq > 0 do
    case link_digest(prev, seq, dh, ledger) do
      ^root -> :ok
      other -> {:error, {:link_mismatch, expected: other, got: root}}
    end
  end

  defp verify_link(1, prev, _seq, dh, _ledger, root) do
    case legacy_link(prev, dh) do
      ^root -> :ok
      other -> {:error, {:link_mismatch, expected: other, got: root}}
    end
  end

  defp verify_link(gen, _prev, _seq, _dh, _ledger, _root)
       when is_integer(gen) do
    {:error, {:unknown_chain_gen, gen}}
  end

  defp verify_link(_gen, _prev, _seq, _dh, _ledger, _root) do
    {:error, :non_integer_chain_gen}
  end

  # transactionId is the per-ledger display id "<seq>.<index>"; the seq is
  # the leading integer before the dot.
  defp seq_of(%{"transactionId" => tx}) when is_binary(tx) do
    case Integer.parse(tx) do
      {seq, _rest} when seq > 0 -> seq
      :error -> 0
    end
  end

  defp seq_of(_), do: 0
  @spec append(String.t(), map()) ::
          {:ok, map()} | {:error, pos_integer(), map()}
  def append(ledger, contents, opts \\ [])
      when is_binary(ledger) and is_map(contents) do
    ensure_started()
    GenServer.call(__MODULE__, {:append, ledger, contents, opts}, @call_timeout)
  end

  ## GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Ensure the Store tables exist when the writer is supervised.
    case GenServer.whereis(Store) do
      nil -> Store.start_link(Keyword.get(opts, :store_opts, []))
      _ -> :ok
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:append, ledger, contents, opts}, _from, state) do
    {:reply, do_append(ledger, contents, opts), state}
  end

  ## Internals

  # The existence fence runs INSIDE the serialized critical section (lens-3):
  # a caller-side check raced with the first successful append, so two
  # concurrent cold-start appends could both be spuriously refused 404 (and
  # the flag-flip blast radius was nondeterministic run to run). Behind the
  # writer, first-writer-creates: exactly one of N concurrent cold-start
  # appends succeeds, the rest see an existing ledger.
  defp do_append(ledger, contents, opts) do
    if opts[:enforce_existence] == true and not ledger_exists?(ledger) do
      ledger_error(404, "LedgerNotFound", "Ledger #{ledger} not found.")
    else
      do_append_locked(ledger, contents)
    end
  end

  # A ledger "exists" when it has prior transaction state (latest receipt or a
  # minted sequence counter) or an explicit creation marker.
  defp ledger_exists?(ledger) do
    match?({:ok, _}, Store.get(:smalt_ledger_meta, {:latest, ledger})) or
      match?({:ok, n} when is_integer(n) and n > 0, Store.get(:smalt_ledger_meta, {:seq, ledger})) or
      match?({:ok, _}, Store.get(:smalt_ledger_meta, {:created, ledger}))
  end

  defp do_append_locked(ledger, contents) do
    # Commit-point law (lens-4): the encode is the FIRST state-touching step
    # and the only step that can fail on caller-supplied data. A failure here
    # must be a typed refusal — never an exception escaping the serialized
    # writer (which would kill the writer for all writers) and never a burned
    # counter (a later valid append of the same contents must be admitted).
    case encode_contents(contents) do
      {:ok, data_hash} ->
        try do
          do_append_valid(ledger, contents, data_hash)
        catch
          {:ledger_sign_refused, _ledger} ->
            ledger_error(400, "InvalidLedgerItem", "Ledger item could not be signed.")
        end

      :error ->
        ledger_error(400, "InvalidBody", "Request body could not be encoded as canonical JSON.")
    end
  end

  # R143-era convention: the writer returns the full Azure-style error
  # envelope so the egress router renders it directly via blob_error/3 —
  # no per-arm not_found_error/put_message fabrication.
  defp ledger_error(status, code, message) do
    {:error, status, %{"error" => %{"code" => code, "message" => message}}}
  end

  # Total: the canonicalization itself can raise on hostile key shapes (e.g.
  # `to_string/1` on a tuple key — lens-5), not just the JSON encode, so the
  # whole encode step is guarded. Any failure is the same typed 400 refusal:
  # the writer never dies on caller-supplied data.
  defp encode_contents(contents) do
    {:ok, json} = safe_encode(contents)
    {:ok, hash(json)}
  rescue
    _ -> :error
  end

  defp safe_encode(contents) do
    contents
    |> canonical()
    |> Jason.encode()
  end

  defp do_append_valid(ledger, contents, data_hash) do
    # Real-Azure law: every append commits. Identical contents are NOT deduped
    # (Azure Confidential Ledger returns a NEW transactionId per append); the
    # ledger is append-only history, so a replay append gets a fresh tx id.
    # (The former {:dup, ledger, data_hash} counter refused replays with 409
    # LedgerItemAlreadyExists — removed; warm-replay appends now commit.)
    prev_hash = latest_root(ledger)
    seq = Store.update_counter(:smalt_ledger_meta, {:seq, ledger}, 1)
      # Identity law (i29-ledger-txid-qualify): tx_id is a PER-LEDGER display
      # id ("N.1"). It is UNIQUE only within `ledger`; the store key below is
      # the ledger-qualified identity ("#{ledger}/#{tx_id}"). The wire form is
      # pinned (strata_compat/security_hardening/ledger.probe round-trip it),
      # so it is deliberately NOT minted qualified — any cross-ledger consumer
      # (semantic projection, tests) must match on {subLedgerId, transactionId}.
    tx_id = "#{seq}.1"
    # Chain-gen-2 link: BLAKE3 over domain || raw32(prev) || u64BE(seq) ||
    # raw32(data_hash) || sub_ledger_id — binds seq and ledger id into the
    # digest. prev_hash may be a legacy gen-1 sha256 hex root (seam
    # continuity: raw-decoded the same way); data_hash stays sha256.
    merkle_root = link_digest(prev_hash, seq, data_hash, ledger)

    receipt = %{
      "transactionId" => tx_id,
      "subLedgerId" => ledger,
      "chain_gen" => @chain_gen,
      "data_hash" => data_hash,
      "prev_hash" => prev_hash,
      "merkle_root" => merkle_root,
      "contents" => contents,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Sign is the last step that can fail on caller-supplied data (the
    # receipt embeds the raw `contents` and the raw `ledger` name, either of
    # which may be non-UTF8 even when the canonical encode in
    # encode_contents/1 succeeded — lens-4 commit-point law). A sign failure
    # must be a typed refusal that compensates the minted counter, never an
    # exception escaping the serialized writer (writer death = broken chain
    # for subsequent appends). SHIM-COURT-eligible seam.
    signature =
      try do
        receipt |> Map.delete("signature") |> ReceiptSigner.sign()
      rescue
        e ->
          # JA-R1 (V4): the typed {:ledger_sign_refused, ledger} refusal is
          # unchanged (compensation below still runs); the swallow is no
          # longer silent — the caller-side refusal is now operator-visible.
          Logger.error(
            "ledger_writer: sign failed for #{ledger}, refusing {:ledger_sign_refused, #{inspect(ledger)}}: #{Exception.message(e)}"
          )

          # Compensate: the append never committed, so the seq counter
          # returns to its pre-call value and a later VALID append is
          # admitted with the same tx id (no burned id, no seq gap).
          Store.update_counter(:smalt_ledger_meta, {:seq, ledger}, -1)
          throw({:ledger_sign_refused, ledger})
      end

    receipt = Map.put(receipt, "signature", signature)

    Store.put(:smalt_ledger_transactions, "#{ledger}/#{tx_id}", receipt)
    Store.put(:smalt_ledger_meta, {:latest, ledger}, receipt)

    {:ok, receipt}
  end

  defp latest_root(ledger) do
    case Store.get(:smalt_ledger_meta, {:latest, ledger}) do
      {:ok, %{"merkle_root" => root}} -> root
      :error -> @zero_hash
    end
  end

  defp hash(binary), do: Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

  # Normalizes to string keys recursively; Jason encodes map keys in sorted
  # order, so the resulting JSON is canonical (sorted-key) JSON.
  defp canonical(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Map.new()
  end

  defp canonical(other), do: other

  # Lazy, unlinked start so appends work from any process (tests that never
  # started a supervisor, Bandit request tasks). Unlinked: a caller exiting
  # must not kill the serialized writer mid-chain. The registration race is
  # safe: exactly one start wins the name; losers proceed to the call.
  defp ensure_started do
    if GenServer.whereis(__MODULE__) == nil do
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
