defmodule Smalt.Security.ConfidentialLedger do
  @moduledoc """
  Pure-Elixir append-only Merkle-chain ledger emulation for Azure Confidential
  Ledger (`Microsoft.ConfidentialLedger/ledgers`).

  Per-ledger monotonic transaction ids (`"<seq>.1"`) are minted through
  `Smalt.Store.update_counter/3` (GenServer-free ETS atomic increment), the
  Merkle root is `sha256(prev_root <> data_hash)`, duplicate contents are
  rejected per ledger with HTTP 409, and every entry carries a signed receipt.
  """

  alias Smalt.Security.LedgerWriter
  alias Smalt.Store

  @latest_key_suffix "latest"

  @doc """
  Appends `contents` to `ledger`. Returns `{:ok, receipt}` or
  `{:error, 409, "LedgerItemAlreadyExists"}` when identical contents already
  exist in this ledger.
  """
  @spec append_transaction(String.t() | atom, map(), keyword()) ::
          {:ok, map()} | {:error, 404, String.t()} | {:error, 409, String.t()}
  def append_transaction(ledger, contents, _opts \\ []) when is_map(contents) do
    ledger = to_string(ledger)

    # Existence fence (lane ledger-skr lens-2, coordinator-authorized fence
    # only): Azure Confidential Ledger returns 404 for an append to a
    # never-created ledger; smalt's append path lazily materializes it. The
    # default keeps the emulated behavior (implicit create — a documented
    # divergence, pinned by test); when `:ledger_enforce_existence` is set,
    # appends to a ledger with no prior state and no explicit creation marker
    # (`{:created, ledger}` in `:smalt_ledger_meta`) are refused with the
    # 404-class envelope, proving the fix shape for the coordinated pivot.
    if Application.get_env(:smalt, :ledger_enforce_existence, false) do
      # The fence is evaluated inside the serialized writer (lens-3, TOCTOU
      # repair): concurrent cold-start appends resolve first-writer-creates
      # instead of racing the caller-side check.
      LedgerWriter.append(ledger, contents, enforce_existence: true)
    else
      # The full append is one critical section inside the serialized
      # LedgerWriter: prev-root read, seq increment, dup check, insert and meta
      # update can never interleave, so the chain cannot fork under a race.
      LedgerWriter.append(ledger, contents)
    end
  end

  @doc """
  Fetches a receipt by `tx_id` (`"N.1"`) or `"latest"` for the ledger.
  Returns `{:ok, receipt}` or `:error`.
  """
  @spec get_transaction(String.t() | atom, String.t()) :: {:ok, map()} | :error
  def get_transaction(ledger, @latest_key_suffix) do
    get_latest(ledger)
  end

  def get_transaction(ledger, tx_id) do
    Store.get(:smalt_ledger_transactions, "#{to_string(ledger)}/#{tx_id}")
  end

  @doc """
  Lists all receipts for `ledger` in transaction-id order (monotonic seq order).
  """
  @spec list_transactions(String.t() | atom) :: [map()]
  def list_transactions(ledger) do
    ledger = to_string(ledger)

    Store.list_prefix(:smalt_ledger_transactions, "#{ledger}/")
    |> sort_tx_keys()
  end

  @doc """
  Returns `{:ok, latest_receipt}` or `:error` when the ledger is empty.
  """
  @spec get_latest(String.t() | atom) :: {:ok, map()} | :error
  def get_latest(ledger) do
    Store.get(:smalt_ledger_meta, {:latest, to_string(ledger)})
  end

  ## Internals

  defp sort_tx_keys(receipts) do
    Enum.sort_by(receipts, fn %{"transactionId" => tx_id} ->
      case String.split(tx_id, ".", parts: 2) do
        [seq, sub] -> {String.to_integer(seq), String.to_integer(sub)}
        _ -> {0, 0}
      end
    end)
  end
end
