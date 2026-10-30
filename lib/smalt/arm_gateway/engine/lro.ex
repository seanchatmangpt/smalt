
defmodule Smalt.ArmGateway.Engine.Lro do
  @moduledoc """
  LRO wire-shaping engine (T06, v26.10.29): async response minting and
  terminal poll-body enrichment, extracted verbatim from the router.
  """

  import Plug.Conn
  require Logger
  import Smalt.ArmGateway.Plug.Common
  alias Smalt.Store



  # LRO PUT async response: polling URLs resolve from the client's seat — the
  # same request-authority derivation the OIDC envelopes use (never a hardcoded
  # management.smalt.local).
  def async_put_response(conn, status, op) do
    authority = request_authority(conn)

    conn
    |> put_resp_header("azure-asyncoperation", "#{authority}#{op["id"]}")
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(status, Jason.encode!(op))
  end

  # WO-19 (v26.10.31 lane 14): the envelope vocabulary moved to
  # Smalt.ArmGateway.Engine.LroEnvelope (canonical: posh
  # internal/dialect/azure/lro.go — byte-parity court
  # lro_parity_test.go). This module keeps only the vendor-neutral state
  # machine (record + clock + fail-closed + Sweeper/Notifier).
end
