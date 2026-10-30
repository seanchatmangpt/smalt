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

  # G26 option (a): the fence policy for the arm.request route. Required-keys
  # stay empty so no legitimate ARM write shape is refused (RG/containerApp/
  # secret PUT bodies are JSON objects); the fence refuses payloads that are
  # not JSON objects at all (e.g. a bare JSON array) — the delta class the
  # falsifier drives. Policy override via config :smalt, :turnstile_fence,
  # policy: <map> (pre-compile shape, same keys as Admission.compile/1).
  @default_fence_policy %{"arm.request" => %{required: [], types: %{}}}

  def init(opts), do: opts

  # Stamp-only mount (router.ex:46, above Bearer): unchanged byte contract.
  def call(conn, :stamp), do: stamp(conn)

  # Fence mount (router.ex, immediately after Plug.Parsers): consults the
  # generated pipeline's Admission for MUTATING verbs on /subscriptions/*
  # resource paths. Config-gated `config :smalt, :turnstile_fence`; charter
  # posture is ON (enabled defaults TRUE — disclosed choice, lane 39/G26).
  # The fence's EventLog server is ensured per-request (unlinked start,
  # idempotent on the already-started case): a default boot without
  # `config :smalt, :posh` still gets a real, persisted settlement log at
  # `tmp/posh/events.ndjson` (or cfg `:dir`) instead of a crash or a
  # silent no-log fake pass.
  def call(conn, :fence) do
    cfg = Application.get_env(:smalt, :turnstile_fence, [])

    if Keyword.get(cfg, :enabled, true) and mutating?(conn.method) and
         resource_delta_path?(conn) do
      log_name = Keyword.get(cfg, :log_name, Smalt.Posh.Egress.EventLog)
      ensure_log!(log_name, Keyword.get(cfg, :dir, "tmp/posh"))
      admit(conn, cfg, log_name)
    else
      conn
    end
  end

  defp ensure_log!(log_name, dir) do
    if Process.whereis(log_name) do
      :ok
    else
      # Unlinked start: the log outlives any single request process.
      case GenServer.start(Smalt.Posh.Egress.EventLog, [dir: dir], name: log_name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  def call(conn, _opts), do: stamp(conn)

  defp stamp(conn) do
    ts_ns = System.system_time(:nanosecond)

    Plug.Conn.register_before_send(conn, fn conn ->
      # Read at send time: smalt_raw_body is stable by then (BodyCache has
      # run); nil before Parsers → "" fallback.
      body = conn.private[:smalt_raw_body] || ""
      receipt = Smalt.Posh.Egress.Settlement.digest(@op, ts_ns, body)
      receipt_hex = Base.encode16(receipt, case: :lower)

      # G26: an admitted delta's settlement landed in the fence branch (via
      # Turnstile.admit -> Settlement.settle); a REFUSED delta never reaches
      # settlement, so its receipt (the same op/ts/body digest as the stamped
      # header) is settled here — the event log carries the refusal, not just
      # the wire.
      case conn.private[:smalt_turnstile_refused] do
        nil ->
          :ok

        refused_reason ->
          settle_refusal!(
            Application.get_env(:smalt, :turnstile_fence, [])
            |> Keyword.get(:log_name, Smalt.Posh.Egress.EventLog),
            %{
              kind: "refusal",
              receipt: receipt_hex,
              node_id: "smalt-node-1",
              state_root: "smalt",
              timestamp_ns: ts_ns,
              delta: %{route: @op, reason: inspect(refused_reason)}
            }
          )
      end

      conn
      |> Plug.Conn.put_resp_header("x-smalt-receipt-turnstile", receipt_hex)
      |> Plug.Conn.put_resp_header("x-smalt-receipt-timestamp", Integer.to_string(ts_ns))
    end)
  end

  # ---------------------------------------------------------------------------
  # Fence (G26 option (a)): consult the generated pipeline's Admission for
  # mutating ARM resource deltas; a typed refusal halts with a 400 ARM
  # envelope. The refusal is settled into the event log by the stamp
  # before_send above (same op/ts/body digest as the stamped header).
  # ---------------------------------------------------------------------------

  defp admit(conn, cfg, log_name) do
    policy =
      Keyword.get_lazy(cfg, :policy, fn ->
        Smalt.Posh.Ingress.Admission.compile(@default_fence_policy)
      end)

    state = %{
      policy: policy,
      route: @op,
      log_name: log_name
    }

    # Plug.Parsers wraps a non-object JSON body (array/string/number) as
    # %{"_json" => value}; the DELTA is the wrapped value, not the wrapper.
    payload = Map.get(conn.body_params, "_json", conn.body_params)

    case Smalt.Posh.Pipeline.Arm_request.admit(payload, state) do
      {:ok, _settlement} ->
        conn

      {:refused, reason} ->
        reason_text =
          case reason do
            {:shape_violation, %{violations: vs}} ->
              "payload violates the arm.request shape: " <> inspect(vs)

            other ->
              "payload refused by turnstile admission: " <> inspect(other)
          end

        conn
        |> Plug.Conn.put_private(:smalt_turnstile_refused, reason)
        |> Smalt.ArmGateway.Plug.Common.send_arm_error(
          400,
          "AdmissionRefused",
          reason_text,
          conn.request_path
        )
        |> Plug.Conn.halt()
    end
  end

  defp mutating?(method), do: method in ["POST", "PUT", "PATCH", "DELETE"]

  # The fence covers ARM resource deltas only: /subscriptions/* paths. STS
  # token POSTs, metadata faces and provider pass-throughs are not deltas.
  defp resource_delta_path?(conn),
    do: match?(["subscriptions" | _], conn.path_info)

  # Best-effort settlement of the refusal into the append-only event log:
  # a silent skip would be a fake pass, so when the EventLog server is not
  # running (default boots without config :smalt, :posh) the omission is
  # LOUD — warn log naming the exact config that turns settlement on.
  defp settle_refusal!(log_name, entry) do
    if whereis = Process.whereis(log_name) do
      {:ok, _} = Smalt.Posh.Egress.EventLog.append(log_name, entry)
      :ok
    else
      require Logger

      Logger.warning(
        "turnstile fence refused a delta but no event log is running " <>
          "(whereis #{inspect(log_name)} == nil); start config :smalt, :posh " <>
          "to persist refusal receipts"
      )

      :log_not_running
    end
  end
end
