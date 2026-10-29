defmodule Smalt.ConfidentialLedger.Router do
  @moduledoc """
  AZ-3 — the Azure Confidential Ledger REST face (Plug router) over the
  journal substrate, served by `Smalt.ConfidentialLedger.Service`.

  Endpoints (Azure Confidential Ledger REST, `api-version=2022-05-17`):

    * `POST /app/transactions` `{"contents": ...}` → `201 {"transactionId":
      "N.1", "contents": ..., "subLedgerId": "default_ledger", "timestamp":
      "<iso8601>"}` (PENDING until certification); body is refused (400
      `InvalidBody`) unless it is an object with `contents` (or is itself
      the contents object).
    * `GET /app/transactions?api-version=&rangeBegin=&rangeEnd=` →
      `{"transactions": [...], "nextRangeLink": ...}`.
    * `GET /app/transactions/latest?api-version=` → the highest-seq entry.
    * `GET /app/transactions/{txId}?api-version=` →
      `{"entry": {"contents", "transactionId"}, "state": "Committed"|"Pending"}`.
    * `GET /app/transactions/{txId}/receipt?api-version=` → the ACL JSON
      receipt (`leaf` / `root` / `proof`), re-verified fail-closed against
      the sealed segment bytes at read time.
    * `GET /app/transactions/{txId}/certificate?api-version=` → the VC 2.0
      export (`Smalt.Receipt.VcExport`) of the same receipt — the
      certificate endpoint variant.

  Typed refusals: unknown tx → 404 `TransactionNotFound`; not yet certified
  → 409 `TransactionNotCertified`; tampered/quarantined segment → 409
  `LedgerIntegrityFailure` (SJ-2 law); degraded sink → 503 `LedgerDegraded`
  (A-1 law: an accepted-and-dropped append must never read as an admission).

  KD-COVERS: KD-170 (the receipt `proof` is a full-witness sha256-chain
  fold, not a CCF sparse Merkle proof; served on a dedicated port — 8443
  `/app/*` remains the ETS-ledger face). Mount: `Bandit`/`Plug` on its own
  port with `plug: Smalt.ConfidentialLedger.Router`; requires a running
  `Smalt.Storage.JournalSink` + `Smalt.ConfidentialLedger.Service` (both
  configured with the same journal `dir`).
  """

  use Plug.Router

  plug :fetch_query_params
  plug :match
  plug :dispatch

  post "/app/transactions" do
    case read_json(conn) do
      {:ok, %{"contents" => contents} = params} when contents != nil ->
        append(conn, Map.get(params, "ledgerId") || contents, contents)

      {:ok, %{} = contents} when contents != %{} ->
        append(conn, contents, contents)

      {:ok, _} ->
        invalid_body(conn)

      {:error, _} ->
        invalid_body(conn)
    end
  end

  get "/app/transactions" do
    rb = q(conn, "rangeBegin")
    re = q(conn, "rangeEnd")

    # EXPL-11 F1: a malformed range is refused at the boundary (400, real ACL
    # validates transactionId ranges) — never a silent seq-0 coercion (200
    # with ALL transactions) and never a binary_to_integer crash in
    # handle_call (loopable unauthenticated DoS).
    case Smalt.ConfidentialLedger.Service.valid_range(rb, re) do
      :ok ->
        case Smalt.ConfidentialLedger.Service.transactions(rb, re) do
          {:ok, page} ->
            json(conn, 200, page)

          {:error, {:integrity, _}} ->
            integrity_failure(conn)
        end

      {:error, :invalid_range} ->
        invalid_range(conn)
    end
  end

  get "/app/transactions/latest" do
    case Smalt.ConfidentialLedger.Service.transactions(nil, nil, 1_000_000) do
      {:ok, %{"transactions" => txs}} when txs != [] ->
        %{"transactionId" => id} = List.last(txs)
        entry(conn, id)

      {:ok, _} ->
        not_found(conn)

      {:error, {:integrity, _}} ->
        integrity_failure(conn)
    end
  end

  get "/app/transactions/:tx_id" do
    entry(conn, tx_id)
  end

  get "/app/transactions/:tx_id/receipt" do
    case Smalt.ConfidentialLedger.Service.receipt(tx_id) do
      {:ok, r} ->
        json(conn, 200, r)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :not_certified} ->
        not_certified(conn)

      {:error, {:integrity, _}} ->
        integrity_failure(conn)
    end
  end

  get "/app/transactions/:tx_id/certificate" do
    case Smalt.ConfidentialLedger.Service.certificate(tx_id) do
      {:ok, vc} ->
        json(conn, 200, vc)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :not_certified} ->
        not_certified(conn)

      {:error, {:integrity, _}} ->
        integrity_failure(conn)

      {:error, _} ->
        invalid_body(conn)
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => %{"code" => "NotFound"}}))
  end

  ## -- helpers ---------------------------------------------------------------

  defp append(conn, _ledger_id, contents) do
    case Smalt.ConfidentialLedger.Service.append(contents) do
      {:ok, tx_id} ->
        # D7 ledger/append envelope parity: the documented Confidential Ledger
        # append response carries {transactionId, contents, subLedgerId,
        # timestamp}; the 201 previously echoed only transactionId (recorded
        # athena divergence ledger/append@key-missing:contents/subLedgerId/
        # timestamp).
        json(conn, 201, %{
          "transactionId" => tx_id,
          "contents" => contents,
          "subLedgerId" => "default_ledger",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, :ledger_degraded} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{"error" => %{"code" => "LedgerDegraded"}}))
    end
  end

  defp entry(conn, tx_id) do
    case Smalt.ConfidentialLedger.Service.transaction(tx_id) do
      {:ok, tx} ->
        json(conn, 200, %{
          "entry" => %{"contents" => tx["contents"], "transactionId" => tx_id},
          "state" => tx["state"]
        })

      {:error, :not_found} ->
        not_found(conn)

      {:error, {:integrity, _}} ->
        integrity_failure(conn)
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp invalid_body(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => %{"code" => "InvalidBody"}}))
  end

  defp invalid_range(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => %{"code" => "InvalidRange"}}))
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => %{"code" => "TransactionNotFound"}}))
  end

  defp not_certified(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(409, Jason.encode!(%{"error" => %{"code" => "TransactionNotCertified"}}))
  end

  defp integrity_failure(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(409, Jason.encode!(%{"error" => %{"code" => "LedgerIntegrityFailure"}}))
  end

  defp q(conn, name) do
    case conn.query_params[name] do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  # No Plug.Parsers in front of this router (it is mounted standalone):
  # parse the raw body here so the face is self-contained.
  defp read_json(conn) do
    with {:ok, body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      _ -> {:error, :bad_body}
    end
  end
end
