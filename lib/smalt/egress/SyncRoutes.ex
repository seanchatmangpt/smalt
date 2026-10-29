defmodule Smalt.Egress.SyncRoutes do
  @moduledoc """
  w6R-split delegator (ATH-1, v26.10.22): POST /sync/journal/batch — the
  domain-blind binary sync ingress.

  Body: raw `application/octet-stream` — a concatenation of
  `Smalt.Sync.Frame` frames. Per-frame pipeline: integrity (CRC32) ->
  governance (`Smalt.Sync.Guard.run_guard/2` — the `Smalt.Wasm.Bridge`
  seam; an unset guard admits, same as `Powl2.Executor.run_guard`'s nil
  arm) -> CAS commit (`Smalt.Sync.Store.commit/3`) or ANDON refusal (zero
  store mutation for that frame).

  Wire contract (pinned to the landed ATH-2/PAT-B client):

    * SUCCESS — `200` `{"lastSeq":N,"receiptToken":"<640 hex chars>",
      "frames":[...]}`: `receiptToken` is the 320-byte seal
      (`Smalt.Sync.Receipt`, sha256-chain over admitted frame bytes, the
      exact mirror of `workspace/lib/engine/receipt.ts` `mintReceiptToken`);
      `frames` carries one `{"seq":S,"verdict":"admit"}` per frame in wire
      order.
    * REFUSAL — non-2xx `{"refusal":"<code>","serverHeadSeq":N}`: the typed
      code (`EMPTY` / `SHORT_FRAME` / `BAD_MAGIC` / `BAD_LEN` batch-fatal on
      decode; `BAD_CRC32` per-frame; `SEQ_REGRESSION` per-frame vs the
      per-client committed head; guard ANDON reasons) and the canonical
      committed head the client snaps back to. Processing stops at the
      first refusal; commits already fired stand (prior admits stand). For
      an undecodable header the reported head is 0.

  Kill-on-corrupt face: the batch-fatal decode class answers the typed
  refusal frame + `connection: close`. Documented deviation: a hard
  connection-process kill is not reachable from plug-land (Bandit owns the
  conn process; aborting it would also abort the typed refusal frame), so
  the refusal goes out and the connection closes immediately.

  Fallthrough router — unmatched conns pass through un-halted.
  """

  use Plug.Router
  plug :match
  plug :dispatch

  alias Smalt.Sync.Batch
  alias Smalt.Sync.Guard
  alias Smalt.Sync.Receipt
  alias Smalt.Sync.Store

  @max_batch_bytes 16 * 1024 * 1024

  post "/sync/journal/batch" do
    result = read_full_body(conn, <<>>, @max_batch_bytes)
    route_batch(conn, result)
    halt_if_sent(conn)
  end

  # This delegator is LAST in the w6r_fallthrough chain: a sent response
  # that returns un-halted falls through to the main router's blob splat
  # (kd07 class, witnessed). Halt the moment a response is on the wire.
  defp halt_if_sent(conn) do
    if conn.state in [:sent, :chunked] or conn.halted do
      Plug.Conn.halt(conn)
    else
      conn
    end
  end

  # -- pipeline --------------------------------------------------------------

  defp read_full_body(conn, acc, limit) do
    case Plug.Conn.read_body(conn, length: limit, read_length: 65_536) do
      {:ok, body, _conn} ->
        {:ok, acc <> body}

      {:more, partial, conn} ->
        acc = acc <> partial

        if byte_size(acc) > limit do
          {:error, :too_large}
        else
          read_full_body(conn, acc, limit)
        end

      {:error, _} ->
        {:error, :body_read_failed}
    end
  end

  defp route_batch(conn, {:error, :too_large}), do: refuse(conn, 413, "TOO_LARGE", 0)
  defp route_batch(conn, {:error, :body_read_failed}), do: refuse(conn, 400, "BODY_READ_FAILED", 0)

  defp route_batch(conn, {:ok, body}) do
    client_id = client_id_from(body)

    case Store.baseline(client_id) do
      {:ok, last_seq, _chain} ->
        case Batch.decode(body, last_seq) do
          {:ok, frames} -> process(conn, client_id, frames, [])
          {:error, {:bad_batch, code}} -> refuse(conn, 400, code, client_id)
        end
    end
  end

  # Integrity -> governance -> CAS, in wire order. Processing STOPS at the
  # first refusal (typed non-2xx); commits already fired stand.
  defp process(conn, client_id, [], results), do: finish(conn, client_id, results)

  defp process(conn, client_id, [frame | rest], results) do
    cond do
      Map.get(frame, :refusal) == "BAD_CRC32" ->
        refuse(conn, 400, "BAD_CRC32", client_id)

      Map.get(frame, :refusal) == "SEQ_REGRESSION" ->
        refuse(conn, 409, "SEQ_REGRESSION", client_id)

      true ->
        case Guard.run_guard(frame.payload, nil) do
          {:admit, _} ->
            case Store.commit(client_id, frame.seq, frame.wire) do
              {:ok, _} ->
                process(conn, client_id, rest, [admitted(frame.seq) | results])

              {:error, :seq_regression} ->
                refuse(conn, 409, "SEQ_REGRESSION", client_id)
            end

          {:andon, <<1::8, _len::16, reason::binary>>} ->
            refuse(conn, 422, reason, client_id)
        end
    end
  end

  defp finish(conn, client_id, results_rev) do
    results = Enum.reverse(results_rev)
    {:ok, last_seq, chain} = Store.baseline(client_id)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "lastSeq" => last_seq,
        "receiptToken" => Receipt.mint(chain),
        "frames" => results
      })
    )
  end

  # The canonical committed head at refusal time — the client snaps back to
  # it. An undecodable header class reports head 0.
  defp refuse(conn, status, code, client_id) do
    head =
      case Store.baseline(client_id) do
        {:ok, last_seq, _} -> last_seq
      end

    conn
    |> put_resp_header("connection", "close")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"refusal" => code, "serverHeadSeq" => head}))
  end

  # The client identity is the first frame header's CLIENT_ID field — the
  # leading 8 bytes after magic+len; an unreadable header reports 0.
  defp client_id_from(body) do
    case body do
      <<_magic::32, _len::32, client_id::64, _rest::binary>> -> client_id
      _ -> 0
    end
  end

  defp admitted(seq), do: %{"seq" => seq, "verdict" => "admit"}
end
