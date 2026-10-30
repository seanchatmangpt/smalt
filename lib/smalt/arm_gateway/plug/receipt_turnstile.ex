defmodule Smalt.ArmGateway.Plug.ReceiptTurnstile do
  @moduledoc """
  DoD Gate 4: `X-Smalt-Receipt-Turnstile` =
  BLAKE3("arm.request" || u64BE(ts_ns) || raw body) on every membrane-served
  ARM operation. Mounted above `Smalt.Auth.Bearer` (SHIM-COURT X1: moved from
  below `Plug.Parsers`) so pre-membrane rejections — Bearer 401s and
  XArrCert refusals — also carry receipts. The raw body is read INSIDE the
  `register_before_send` closure from `conn.private[:smalt_raw_body]`
  (cached by `Smalt.Auth.BodyCache` during `Plug.Parsers`, which runs after
  this plug): by send time the cache is populated; before Parsers it is nil
  and the `|| ""` fallback applies (digest of the empty body, correct for
  rejection responses that never see a body).

  Crash-path 500s DO carry the receipt: `Plug.ErrorHandler` →
  `send_resp/3` still runs before_send callbacks. The remaining receipt
  gaps are (a) requests rejected before this plug mounts (nothing above
  Bearer in the pipeline) and (b) requests rejected by `Plug.Parsers`
  itself (400 before the conn reaches later plugs' before_send hooks —
  Parsers raises, the error handler sends without this plug's callback).

  Byte contract shared with the Go verifier (`posh/internal/receipt`):
  op || u64BE(ts_ns) || raw_body — no length prefixes, no separators.
  Cross-language pinned vector: 0c39d201b2fc87a2171046f1e76f8afc5398263d888381ee9f24cae4cabdb834.
  """

  @op "arm.request"

  def init(opts), do: opts

  def call(conn, _opts) do
    ts_ns = System.system_time(:nanosecond)

    Plug.Conn.register_before_send(conn, fn conn ->
      # Read at send time: smalt_raw_body is stable by then (BodyCache has
      # run); nil before Parsers → "" fallback.
      body = conn.private[:smalt_raw_body] || ""
      receipt = Smalt.Posh.Egress.Settlement.digest(@op, ts_ns, body)

      conn
      |> Plug.Conn.put_resp_header("x-smalt-receipt-turnstile", Base.encode16(receipt, case: :lower))
      |> Plug.Conn.put_resp_header("x-smalt-receipt-timestamp", Integer.to_string(ts_ns))
    end)
  end
end
