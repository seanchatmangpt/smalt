defmodule Smalt.Egress.AttestRoutes do
  @moduledoc """
  w6R structural split of Smalt.EgressRouter (BEAM implementation limit,
  function '__MODULE__'/1+14): Attestation+Ledger (/attest, /app/transactions) arm, verbatim relocation.
  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """
  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]
  alias Smalt.Security.Attestation
  alias Smalt.Security.ConfidentialLedger
  plug :match
  plug :dispatch



  post "/attest/:type" do
    if not_ready?(conn, [Attestation]) do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        attest_dispatch(conn, type, conn.body_params)
      end)
    end
  end

  # AZ-2 (v26.10.22): MAA wire shape (`Smalt.Attestation.Maa` moduledoc cites
  # the REST doc): POST /attest/:type?api-version=2022-08-01 with
  # {report, runtimeData}. A body carrying "report" routes to the MAA face
  # (andon refusal leaves ride the 400 body under "andon"); the legacy
  # baseline body shape keeps its existing contract.
  defp attest_dispatch(conn, type, %{"report" => _} = params) do
    case Smalt.Attestation.Maa.attest(type, params) do
      {:ok, token, claims} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"jwt-token" => token, "claims" => claims}))

      {:error, status, body, andon} ->
        error =
          body
          |> Map.put("andon", andon.json_ld)
          |> Map.update!("error", fn e -> Map.put(e, "andon_ntriples", Smalt.Powl2.Andon.ntriples(andon)) end)

        blob_error(conn, status, error)
    end
  end

  defp attest_dispatch(conn, type, params) do
    case Attestation.attest_enclave(params, type) do
      {:ok, token, claims} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"token" => token, "claims" => claims}))

      {:error, status, code} ->
        blob_error(conn, status, %{"error" => %{"code" => code}})
    end
  end

  # ---------------------------------------------------------------------------
  # Azure Confidential Ledger (/app/transactions)
  # ---------------------------------------------------------------------------
  get "/app/transactions" do
    if not_ready?(conn, [ConfidentialLedger]) or not tables_ready?([:smalt_ledger_transactions]) do
      route_not_ready(conn)
    else
      send_json(conn, 200, ConfidentialLedger.list_transactions("default_ledger"))
    end
  end

  get "/app/transactions/latest" do
    if not_ready?(conn, [ConfidentialLedger]) or
         not tables_ready?([:smalt_ledger_transactions, :smalt_ledger_meta]) do
      route_not_ready(conn)
    else
      case ConfidentialLedger.get_latest("default_ledger") do
        {:ok, receipt} -> send_json(conn, 200, receipt)
        :error -> blob_error(conn, 404, not_found_error("TransactionNotFound"))
      end
    end
  end

  get "/app/transactions/:tx_id" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      case ConfidentialLedger.get_transaction("default_ledger", tx_id) do
        {:ok, receipt} -> send_json(conn, 200, receipt)
        :error -> blob_error(conn, 404, not_found_error("TransactionNotFound"))
      end
    end
  end
end
