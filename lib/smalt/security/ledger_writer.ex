defmodule Smalt.Security.LedgerWriter do
  @moduledoc """
  Single serialized writer for the Confidential Ledger Merkle chain.

  The append path (duplicate check -> prev-root read -> seq increment ->
  receipt build + sign -> transaction/meta insert) must be one critical
  section: previously `latest_root/1` was read outside the seq increment, so
  two concurrent appends could both chain off the same `prev_hash` and fork
  the ledger. A single named GenServer makes the whole append atomic per
  ledger (in fact globally serialized).

  Started lazily on first append (unlinked, so a short-lived request process
  exiting cannot take the writer down); the name registration race resolves
  with exactly one writer.
  """

  use GenServer

  alias Smalt.Security.ReceiptSigner
  alias Smalt.Store

  @zero_hash String.duplicate("0", 64)
  @call_timeout 30_000

  @doc """
  Appends `contents` to `ledger` atomically. Returns `{:ok, receipt}` or
  `{:error, 409, "LedgerItemAlreadyExists"}` when identical contents already
  exist in this ledger.
  """
  @spec append(String.t(), map()) :: {:ok, map()} | {:error, 409, String.t()}
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
      {:error, 404, "LedgerNotFound"}
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
      {:ok, data_hash} -> do_append_valid(ledger, contents, data_hash)
      :error -> {:error, 400, "InvalidBody"}
    end
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

    # Atomic duplicate detection: first append leaves the counter at 1; any
    # later append of identical contents increments past it and is refused.
    if Store.update_counter(:smalt_ledger_meta, {:dup, ledger, data_hash}, 1) > 1 do
      {:error, 409, "LedgerItemAlreadyExists"}
    else
      prev_hash = latest_root(ledger)
      seq = Store.update_counter(:smalt_ledger_meta, {:seq, ledger}, 1)
      tx_id = "#{seq}.1"
      merkle_root = hash(prev_hash <> data_hash)

      receipt = %{
        "transactionId" => tx_id,
        "subLedgerId" => ledger,
        "data_hash" => data_hash,
        "prev_hash" => prev_hash,
        "merkle_root" => merkle_root,
        "contents" => contents,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      signature = receipt |> Map.delete("signature") |> ReceiptSigner.sign()
      receipt = Map.put(receipt, "signature", signature)

      Store.put(:smalt_ledger_transactions, "#{ledger}/#{tx_id}", receipt)
      Store.put(:smalt_ledger_meta, {:latest, ledger}, receipt)

      {:ok, receipt}
    end
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
