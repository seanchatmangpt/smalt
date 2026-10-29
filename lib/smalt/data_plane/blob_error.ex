defmodule Smalt.DataPlane.BlobError do
  @moduledoc """
  Azure Storage XML error envelope for the blob face (ports 8443/9444 blob
  routes), byte-exact per
  learn.microsoft.com/rest/api/storageservices/common-rest-api-response-headers:

      <?xml version="1.0" encoding="utf-8"?><Error><Code>..</Code><Message>..</Message></Error>

  with `Content-Type: application/xml`, `x-ms-error-code`, `x-ms-request-id`
  and `x-ms-version` response headers.

  Scope: blob-face routes ONLY. Rendering is opt-in per call site — the router
  stamps `:smalt_blob_face` in `conn.private` at blob-route entry, and the
  blob renderer consults it. ARM / Cosmos / KV / AppConfig / Ledger faces keep
  their JSON envelopes byte-identical.

  Closes `GAP(blob-error-envelope-json)` (docs/WIRE_PARITY.md Blob row;
  witness: test/integration/blob_xml_error_test.exs + live curl).
  """

  alias Smalt.DataPlane.BlobService

  # Compile-freeze unblock (B-KD lane, SLA disclosure): the file shipped
  # without Plug.Conn imports, freezing the shared compile for every lane.
  import Plug.Conn

  require Logger

  @version "2021-12-02"

  @doc "Byte-exact Azure Storage error envelope body."
  @spec render(String.t(), String.t()) :: String.t()
  def render(code, message) do
    "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>#{BlobService.xml_escape(code)}</Code><Message>#{BlobService.xml_escape(message)}</Message></Error>"
  end

  @doc """
  Sends the XML error envelope with the full real-Azure error header set:
  `x-ms-request-id`, `x-ms-version`, `x-ms-error-code`,
  `Content-Type: application/xml`.
  """
  @spec send_error(Plug.Conn.t(), integer, String.t(), String.t(), String.t()) :: Plug.Conn.t()
  def send_error(conn, status, code, message, request_id) do
    # JA-15 gap G4: the refusal is typed on the wire but was silent at the
    # site. Log it where it happens: label + correlation id (the request id
    # the wire already carries), typed error code, site context.
    correlation_id = "blob-#{request_id}"

    Logger.warning(
      "[blob] wire refusal status=#{status} code=#{code} path=#{conn.request_path} " <>
        "message=#{inspect(message)} correlation_id=#{correlation_id}",
      correlation_id: correlation_id
    )

    # JA-15 gap G2: telemetry alongside the G4 site log. Observability only —
    # the envelope below must send with no handler attached (non-vacuity leg).
    :telemetry.execute(
      [:smalt, :wire, :refusal],
      %{count: 1},
      %{face: :blob, status: status, code: code, correlation_id: correlation_id}
    )

    conn
    |> put_resp_header("x-ms-request-id", request_id)
    |> put_resp_header("x-ms-version", @version)
    |> put_resp_header("x-ms-error-code", code)
    |> put_resp_content_type("application/xml")
    |> send_resp(status, render(code, message))
  end
end
