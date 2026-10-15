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
  def append(ledger, contents) when is_binary(ledger) and is_map(contents) do
    ensure_started()
    GenServer.call(__MODULE__, {:append, ledger, contents}, @call_timeout)
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
  def handle_call({:append, ledger, contents}, _from, state) do
    {:reply, do_append(ledger, contents), state}
  end

  ## Internals

  defp do_append(ledger, contents) do
    data_hash = contents |> canonical() |> Jason.encode!() |> hash()

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
