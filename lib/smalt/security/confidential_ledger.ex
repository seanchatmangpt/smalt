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
  Appends `contents` to `ledger`. Returns `{:ok, receipt}` or a typed error
  envelope `{:error, status, %{"error" => %{"code" => code, "message" => msg}}}`
  (R143-era convention; wire-ready for the egress router).
  """
  @spec append_transaction(String.t() | atom, map(), keyword()) ::
          {:ok, map()}
          | {:error, pos_integer(), map()}
  def append_transaction(ledger, contents, _opts \\ []) when is_map(contents) do
    case ledger_name(ledger) do
      {:ok, ledger} ->
        append_named(ledger, contents)

      :error ->
        # Crash-class law (lens-9): the ledger NAME is caller-shaped data at
        # this public API, exactly like contents (lens-5). A hostile shape
        # (tuple/map/list) must be a typed refusal, never a to_string raise;
        # and 42/nil must not be SILENTLY COERCED into ledgers "42"/"" (the
        # nil case created an anonymous shared ledger).
        {:error, 400, ledger_name_error()}
    end
  end

  defp append_named(ledger, contents) do
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
    # Crash-class law (lens-10): tx_id is caller-shaped data at this public
    # API, exactly like the ledger name (lens-9). A hostile shape (tuple/map/
    # list) must be a typed refusal (:error), never a String.Chars raise from
    # the key interpolation — and 42/nil must not be silently coerced into
    # lookups "42"/"nil".
    with {:ok, ledger} <- ledger_name(ledger),
         {:ok, tx_id} <- tx_id(tx_id) do
      Store.get(:smalt_ledger_transactions, "#{ledger}/#{tx_id}")
    else
      :error -> :error
    end
  end

  # Lens-10 totalization: only the documented tx-id forms are admitted — a
  # non-empty binary (covers "N.1" and "latest") or the "latest" atom. Every
  # other shape is a typed :error at the boundary.
  defp tx_id(tx_id) when is_binary(tx_id) and tx_id != "", do: {:ok, tx_id}
  defp tx_id(@latest_key_suffix), do: {:ok, @latest_key_suffix}
  defp tx_id(_), do: :error

  @doc """
  Lists all receipts for `ledger` in transaction-id order (monotonic seq order).
  """
  @spec list_transactions(String.t() | atom) :: [map()]
  def list_transactions(ledger) do
    case ledger_name(ledger) do
      {:ok, ledger} ->
        Store.list_prefix(:smalt_ledger_transactions, "#{ledger}/")
        |> sort_tx_keys()

      :error ->
        []
    end
  end

  @doc """
  Returns `{:ok, latest_receipt}` or `:error` when the ledger is empty.
  """
  @spec get_latest(String.t() | atom) :: {:ok, map()} | :error
  def get_latest(ledger) do
    case ledger_name(ledger) do
      {:ok, ledger} -> Store.get(:smalt_ledger_meta, {:latest, ledger})
      :error -> :error
    end
  end

  # R66 lane compile-freeze unblock (disclosed in R66 receipt): `=~` is not
  # guard-safe in Elixir 1.19, so the slash fence moved from a defguardp into
  # the clause body (String.contains?/2) — same refusal, same hook point.
  # Lens-9: the ledger name is caller-shaped data at this public API. Binaries
  # and atoms (the documented @spec forms) are admitted; every other shape is a
  # typed refusal at the boundary — never a to_string/1 raise (tuple/map/list),
  # never silent coercion (42 -> "42", nil -> "" anonymous ledger).
  # (lane R75, audit A23/D1): a ledger name containing "/" — no KD row
  # is refused. Storage keys are "#{ledger}/#{tx_id}", so a name like "a/b"
  # stores under keys inside list_prefix("a/") — list_transactions("a") would
  # leak ledger "a/b"'s receipts and get_transaction("a", "b/1.1") would cross
  # ledgers via the tx-id. The fence is here, at the name boundary, so it
  # covers append/get/list/latest uniformly; storage keying is unchanged.
  # (lane R131, adversarial W5-11): a non-UTF8 name like "a\xFF" (no slash)
  # passed the slash-only fence, reached ReceiptSigner.sign, and Jason.encode!
  # raised inside the serialized LedgerWriter GenServer — writer death with the
  # {:dup, ledger, hash} counter already incremented, so every retry 409s
  # LedgerItemAlreadyExists for never-stored content (commit-point law violated).
  # String.valid?/1 is guard-safe alongside the slash check, same typed refusal
  # (:error envelope), same hook point, covering append/get/list/latest uniformly.
  defp ledger_name(name) when is_binary(name) and name != "" do
    if String.contains?(name, "/") or not String.valid?(name) do
      :error
    else
      {:ok, name}
    end
  end

  defp ledger_name(name) when is_atom(name) and not is_nil(name) and name != :"",
    do: ledger_name(Atom.to_string(name))

  # SHIM-COURT hook point: flip the defguardp body to `false` to prove the
  # fence is non-vacuous (a "a/b" ledger must become storable again,
  # re-leaking). defguardp declared above ledger_name/1 (see note there).
  defp ledger_name(_), do: :error

  ## Internals

  # Same envelope builder family as LedgerWriter (R143-era convention):
  # wire-ready map envelope, rendered directly by the egress router.
  defp ledger_name_error do
    %{"error" => %{"code" => "InvalidLedgerName", "message" => "Ledger name is invalid."}}
  end

  defp sort_tx_keys(receipts) do
    Enum.sort_by(receipts, fn %{"transactionId" => tx_id} ->
      case String.split(tx_id, ".", parts: 2) do
        [seq, sub] -> {String.to_integer(seq), String.to_integer(sub)}
        _ -> {0, 0}
      end
    end)
  end
end
