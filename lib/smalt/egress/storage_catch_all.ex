defmodule Smalt.Egress.StorageCatchAll do
  @moduledoc """
  T07 (v26.10.29, L07) w6R-style split of `Smalt.EgressRouter`: the
  `/{account}/...` storage catch-all family, verbatim relocation —

    * G1 Azure Queue Storage plane (queue_plane_route/run_queue_arm/queue_dispatch)
    * File Share plane (file_plane_route/run_file_arm/file_dispatch + senders)
    * G5 tenant fence, RESTORED from the pre-undock source 95d4243d
      (tenant_namespace + the queue/blob shape predicates + fences; the
      coordinator scope addendum for this lane)
    * the guarded blob splat (blob_route/blob_route_guarded/run_guarded +
      reserved fence + comp whitelists) and the blob batch surface

  Mounts (the front router keeps every pre-split pipeline position):

    * `plug(:tenant_namespace)` between `:fetch_query_params` and
      `:trim_dbs_trailing_slash` (the 95d4243d position) — one-line front
      delegate into `tenant_namespace/1` here.
    * `plug(:queue_storage_plane)` + `plug(:file_share_plane)` at the same
      pre-apim positions they held inside the front — one-line front
      delegates into the `queue_storage_plane/1` / `file_share_plane/1`
      functions here.
    * this module's match/dispatch (the blob splat) runs from the front's
      post-dispatch `:storage_dispatch` plug — i.e. AFTER the front's
      literal-prefix families (the pre-split route order) and BEFORE the
      front's typed-404 fallback. Unmatched shapes pass through UNSENT via
      the `match _` pass-through below and the front answers the typed 404.

  Byte-parity notes:
    * `blob_error/3` stays in the front router (external court pin + the B-XML
      consult law) — `blob_route/2` stamps `:smalt_blob_face` exactly as
      before and the consult reads it cross-module, unchanged.
    * the apim gateway plane keeps its L02/L04 position (before w6r/match).
    * the fence's reserved-segment list keeps the 95d4243d content
      (including `v1.0`) as `@tenant_reserved_first_segments` — renamed from
      the history `@reserved_first_segments` because the blob splat's OWN
      `@reserved_first_segments` (current tree, without `v1.0`) also lives
      here and a double definition would silently accumulate.
  """
  use Plug.Router

  # The shared egress helpers stay single-truth in the front router (the
  # delegator pattern: lib/smalt/egress/KvRoutes.ex et al. import + the
  # external court pins) — see the front router for their bodies.
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]

  alias Smalt.Store
  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.QueueStorage

  plug :match
  plug :dispatch

  # GAP-AUD1-01 (v26.10.14, lane W-5): blob comp whitelists — MUST be defined
  # textually BEFORE the route macros that expand them (module attributes are
  # expanded at their point of use, top-to-bottom).
  # KD-COVERS: KD-60 — comp=snapshot is registered (wire arm below).
  # Parity lane 2026-10-28: comp=lease (base blob, no sharesnapshot),
  # appendblock, page and properties (Set Blob HTTP Headers) registered —
  # receipted against Azurite (parity/COVERAGE_VS_TOPAZ.md gap list).
  @blob_put_comps ~w(block blocklist metadata snapshot lease appendblock page properties)
  # KD-COVERS: KD-60 — comp=metadata GET registered (Azure Get Blob Metadata);
  # pagelist/tags stay default-deny.
  @blob_get_comps ~w(blocklist metadata)
  # R98 container comp whitelists — mirror of the blob arms above. Lease and
  # ACL are UNIMPLEMENTED (KD/GAP(blob-comp-lease-absent)); previously an
  # unknown container comp fell through: PUT into the create-container branch
  # (silent 201 lie), GET into the plain-list fallback (wrong-body 200).
  @container_put_comps ~w(legalhold immutabilityPolicy immutabilitypolicy metadata lease acl)
  @container_get_comps ~w(legalhold immutabilityPolicy immutabilitypolicy metadata list acl)

  # ---------------------------------------------------------------------------
  # G1 Azure Queue Storage plane (v26.10.19) — arm BEFORE the blob splat.
  # Queue Storage's REST namespace (/{account}/{queue}/messages...) collides
  # with the guarded blob catch-all at the same /{account}/... prefix; the
  # disambiguation is query-shape detection (scoping doc section 1):
  #   * PUT/DELETE /{account}/{queue}?restype=queue  -> queue lifecycle
  #   * GET    /{account}?comp=list&restype=queue    -> List Queues
  #   * /{account}/{queue}/messages[/{id}]           -> message surface
  # Everything else (:pass) falls through to :match UNCHANGED — the blob
  # splat, Cosmos, KV and every other arm see byte-identical requests.
  # ---------------------------------------------------------------------------

  def queue_storage_plane(conn, _opts \\ nil) do
    qp = fetchd_query_params(conn)

    # Parity lane 2026-10-28: the v12 storage-queue SDK sends
    # `GET /{account}?comp=list` with NO restype (real Azure implies the
    # service by endpoint host) — byte-identical to blob List Containers.
    # On this shared egress port the only deterministic discriminator is
    # the SDK User-Agent (azsdk-js-azure-storage-queue vs -blob); an
    # explicit restype, when present, always wins.
    queue_ua? =
      conn
      |> get_req_header("user-agent")
      |> Enum.any?(&String.contains?(&1, "storage-queue"))

    case queue_plane_route(conn.method, conn.path_info, qp, queue_ua?) do
      nil -> conn
      arm -> run_queue_arm(conn, arm, qp)
    end
  end

  # Parity lane 2026-10-28: reserved first segments that belong to OTHER
  # planes on the shared egress port (cosmos /dbs, KV /keys /secrets /kv,
  # eventgrid, ...) — the bare-2-segment queue arms below must never capture
  # them. Defined BEFORE every queue_plane_route clause that reads it
  # (module attributes resolve in file order).
  @queue_reserved_first_segments ~w(dbs keys secrets kv eventgrid events attest)

  defp queue_plane_route("GET", [account], qp, queue_ua?) do
    cond do
      qp["comp"] == "list" and qp["restype"] == "queue" ->
        {:list_queues, account}

      qp["comp"] == "list" and is_nil(qp["restype"]) and queue_ua? ->
        {:list_queues, account}

      true ->
        nil
    end
  end

  # Parity lane 2026-10-28: bare 2-segment GET (the v12 SDK's
  # Get Queue Properties shape — no restype on the wire), and the SDK's
  # getProperties()/getMetadata() shape `?comp=metadata` without restype
  # (real Azure Get Queue Metadata; the blob container GET always carries
  # restype=container, so the no-restype form is unambiguously queue).
  defp queue_plane_route("GET", [account, queue], qp, _queue_ua?) do
    cond do
      account in @queue_reserved_first_segments -> nil
      qp["restype"] == "queue" -> {:get_queue_props, account, queue}
      is_nil(qp["restype"]) and is_nil(qp["comp"]) -> {:get_queue_props, account, queue}
      qp["comp"] == "metadata" and is_nil(qp["restype"]) ->
        {:get_queue_props, account, queue}

      true ->
        nil
    end
  end

  # Parity lane 2026-10-28: the @azure/storage-queue v12 SDK does NOT send
  # restype=queue on queue create/delete — the service is implied by the
  # endpoint host on real Azure ({account}.queue.core.windows.net). On smalt's
  # single shared egress port the bare 2-segment PUT/DELETE (no comp, no
  # restype) is unambiguous: the blob container arm ALWAYS carries
  # restype=container (SDK-witnessed), so route it to the queue plane.
  defp queue_plane_route("PUT", [account, queue], qp, _queue_ua?) do
    cond do
      account in @queue_reserved_first_segments -> nil
      qp["restype"] == "queue" -> {:create_queue, account, queue}
      is_nil(qp["restype"]) and is_nil(qp["comp"]) -> {:create_queue, account, queue}
      # Queue Set Metadata (comp=metadata, NO restype — the blob container
      # metadata PUT carries restype=container and must NOT be hijacked).
      qp["comp"] == "metadata" and is_nil(qp["restype"]) ->
        {:set_queue_metadata, account, queue}

      true ->
        nil
    end
  end

  defp queue_plane_route("DELETE", [account, queue], qp, _queue_ua?) do
    cond do
      account in @queue_reserved_first_segments -> nil
      qp["restype"] == "queue" -> {:delete_queue, account, queue}
      is_nil(qp["restype"]) and is_nil(qp["comp"]) -> {:delete_queue, account, queue}
      true -> nil
    end
  end

  defp queue_plane_route("POST", [account, _queue, "messages"], _qp, _ua),
    do: {:put_messages, account}

  defp queue_plane_route("GET", [account, _queue, "messages"], qp, _ua),
    do: if(qp["peekonly"] == "true", do: {:peek_messages, account}, else: {:get_messages, account})

  defp queue_plane_route("PUT", [account, _queue, "messages", _id], _qp, _ua),
    do: {:update_message, account}

  # Clear Messages must shadow the popreceipt-carrying delete-message match on
  # path shape alone (3 elements vs 4) — the 3-element DELETE is the clear comp.
  defp queue_plane_route("DELETE", [account, _queue, "messages"], _qp, _ua),
    do: {:clear_messages, account}

  defp queue_plane_route("DELETE", [account, _queue, "messages", _id], _qp, _ua),
    do: {:delete_message, account}

  defp queue_plane_route(_, _, _, _), do: nil

  defp run_queue_arm(conn, arm, qp) do
    if not_ready?(conn, [QueueStorage]) do
      route_not_ready(conn)
    else
      queue_dispatch(conn, arm, qp)
    end
    # The queue arms send their responses inside queue_dispatch; without an
    # explicit halt the plug pipeline CONTINUES into :match and the blob
    # splat re-dispatches the same request (in-process callers crash with
    # AlreadySentError; live Bandit traffic masked it because the response
    # was already on the socket). Halt is the correct terminal behavior for
    # a handled arm. Found by test/integration/parity_lane_wire_test.exs.
    |> Plug.Conn.halt()
  end

  defp queue_dispatch(conn, {:list_queues, account}, qp) do
    case QueueStorage.list_queues(account, qp) do
      {:ok, status, headers, body} ->
        conn
        |> put_resp_headers(headers)
        |> put_resp_content_type("application/xml")
        |> send_resp(status, body)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:create_queue, account, queue}, _qp) do
    case QueueStorage.create_queue(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:delete_queue, account, queue}, _qp) do
    case QueueStorage.delete_queue(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  # Parity lane 2026-10-28: Queue Set Metadata — persists x-ms-meta-* on the
  # queue row (Get Queue Properties reads them back); 204 No Content.
  defp queue_dispatch(conn, {:set_queue_metadata, account, queue}, _qp) do
    case QueueStorage.set_queue_metadata(account, queue, meta_headers(conn)) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:get_queue_props, account, queue}, _qp) do
    case QueueStorage.get_queue_properties(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  # Queue message bodies are XML — Plug.Parsers (json/urlencoded) leaves them
  # unread; read the raw body here. A JSON content-type body would already be
  # consumed by the parsers plug, which is acceptable (Azure clients send XML).
  defp queue_dispatch(conn, {:put_messages, account}, _qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    with {:ok, body, conn} <- read_queue_body(conn) do
      case QueueStorage.put_message(account, queue, body) do
        {:ok, status, headers, resp_body} ->
          conn
          |> put_resp_headers(headers)
          |> put_resp_content_type("application/xml")
          |> send_resp(status, resp_body)

        {:error, status, code, msg} ->
          blob_error(conn, status, not_found_error(code) |> put_message(msg))
      end
    else
      {:error, reason} ->
        blob_error(conn, 400, %{
          "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
        })
    end
  end

  defp queue_dispatch(conn, {:get_messages, account}, qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    case QueueStorage.get_messages(account, queue, qp) do
      {:ok, status, headers, resp_body} ->
        conn
        |> put_resp_headers(headers)
        |> put_resp_content_type("application/xml")
        |> send_resp(status, resp_body)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:peek_messages, account}, qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    case QueueStorage.peek_messages(account, queue, qp) do
      {:ok, status, headers, resp_body} ->
        conn
        |> put_resp_headers(headers)
        |> put_resp_content_type("application/xml")
        |> send_resp(status, resp_body)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:clear_messages, account}, _qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    case QueueStorage.clear_messages(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:update_message, account}, qp) do
    [queue, _, msg_id] = Enum.drop(conn.path_info, 1)

    with {:ok, body, conn} <- read_queue_body(conn) do
      case QueueStorage.update_message(
             account,
             queue,
             msg_id,
             qp["popreceipt"] || "",
             body,
             qp
           ) do
        {:ok, _status, headers, _resp_body} ->
          # Azure parity (parity lane 2026-10-28, receipted vs Azurite):
          # Update Message answers 204 No Content — the @azure SDK
          # type-asserts 204 (RestError "Unexpected status code" otherwise).
          send_headers(conn, 204, headers)

        {:error, status, code, msg} ->
          blob_error(conn, status, not_found_error(code) |> put_message(msg))
      end
    else
      {:error, reason} ->
        blob_error(conn, 400, %{
          "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
        })
    end
  end

  defp queue_dispatch(conn, {:delete_message, account}, qp) do
    [queue, _, msg_id] = Enum.drop(conn.path_info, 1)

    case QueueStorage.delete_message(account, queue, msg_id, qp["popreceipt"] || "", qp) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp read_queue_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # File Share data plane (re-landed from the pre-undock source 95d4243d —
  # the v26.10.29 undock dropped the whole plane; the expl9r1 F2/F4 legs and
  # the KD-175 413 guard kept pinning it). File Share REST face over
  # Smalt.DataPlane.FileShare; claims file-share requests BEFORE match/dispatch
  # and passes everything else through UNCHANGED (nil arm -> conn).
  # ---------------------------------------------------------------------------
  plug(:file_share_plane)

  def file_share_plane(conn, _opts \\ nil) do
    qp = fetchd_query_params(conn)

    case file_plane_route(conn.method, conn.path_info, qp, conn) do
      nil -> conn
      arm -> run_file_arm(conn, arm, qp)
    end
  end

  def file_plane_route("GET", [], qp, _c) do
    if qp["comp"] == "list", do: {:list_shares, nil}
  end

  def file_plane_route("PUT", [s], qp, _c) do
    if qp["restype"] == "share", do: {:create_share, s}
  end

  def file_plane_route(m, [s], qp, _c) when m in ["GET", "HEAD"] do
    cond do
      qp["comp"] == "stats" and qp["restype"] == "share" -> {:get_share_stats, s}
      qp["comp"] == "list" and qp["restype"] == "directory" -> {:list_dir, s, nil}
      qp["restype"] == "share" -> {:get_share_props, s}
      true -> nil
    end
  end

  def file_plane_route("DELETE", [s], qp, _c) do
    if qp["restype"] == "share", do: {:delete_share, s}
  end

  def file_plane_route("PUT", [s, x | rest], qp, c) do
    cond do
      qp["comp"] == "range" -> {:put_range, s, join_segs([x | rest])}
      qp["restype"] == "directory" -> {:create_dir, s, join_segs([x | rest])}
      get_req_header(c, "x-ms-type") == ["File"] -> {:create_file, s, join_segs([x | rest])}
      true -> nil
    end
  end

  # Reserved first segments (w6bk): data-plane namespaces served by the KV /
  # cosmos / table delegators behind this router. The file plane must never
  # claim paths under them — the unfenced GET catch-all shadowed
  # `GET /keys/:name` into a blob-XML 404 (witnessed by lane w6c on v62).
  @file_reserved_first ~w(dbs keys secrets certificates tables colls users permissions)

  # (w6bl SLA unblock: the file_reserved_first?/1 helper was interleaved here,
  # splitting the file_plane_route/4 clause group and tripping the grouped-
  # clauses warning under --warnings-as-errors; relocated below the catch-all.)

  def file_plane_route("GET", [s, x | rest], qp, _c) do
    if file_reserved_first?(s) do
      nil
    else
      cond do
        qp["comp"] == "list" and qp["restype"] == "directory" ->
          {:list_dir, s, join_segs([x | rest])}

        qp["comp"] == "rangelist" ->
          {:get_range_list, s, join_segs([x | rest])}

        qp["restype"] == "directory" ->
          {:get_dir_props, s, join_segs([x | rest])}

        true ->
          {:get_file, s, join_segs([x | rest])}
      end
    end
  end

  def file_plane_route("HEAD", [s | r], qp, c), do: file_plane_route("GET", [s | r], qp, c)

  def file_plane_route("DELETE", [s, x | rest], qp, _c) do
    if file_reserved_first?(s) do
      nil
    else
      cond do
        qp["restype"] == "directory" -> {:delete_dir, s, join_segs([x | rest])}
        true -> {:delete_file, s, join_segs([x | rest])}
      end
    end
  end

  def file_plane_route(_, _, _, _), do: nil

  def file_reserved_first?(first) when is_binary(first),
    do: String.downcase(URI.decode(first)) in @file_reserved_first

  def join_segs(segs), do: Enum.join(segs, "/")

  def run_file_arm(conn, arm, qp) do
    if not_ready?(conn, [Smalt.DataPlane.FileShare]) do
      route_not_ready(conn)
    else
      file_dispatch(conn, arm, qp)
    end
  end

  def file_dispatch(conn, arm, qp) do
    headers = header_map(conn)

    _ = qp

    case arm do
      {:list_shares, _} ->
        {:ok, st, h, b} = Smalt.DataPlane.FileShare.list_shares()
        send_file_xml(conn, st, h, b)

      {:create_share, s} ->
        case Smalt.DataPlane.FileShare.create_share(s, headers) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_share_props, s} ->
        case Smalt.DataPlane.FileShare.get_share_properties(s) do
          {:ok, st, h, nil} -> send_file_headers_only(conn, st, h)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_share_stats, s} ->
        case Smalt.DataPlane.FileShare.get_share_stats(s) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:delete_share, s} ->
        case Smalt.DataPlane.FileShare.delete_share(s) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:create_dir, s, p} ->
        case Smalt.DataPlane.FileShare.create_directory(s, p) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_dir_props, s, p} ->
        case Smalt.DataPlane.FileShare.get_directory_properties(s, p) do
          {:ok, st, h, nil} -> send_file_headers_only(conn, st, h)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:delete_dir, s, p} ->
        case Smalt.DataPlane.FileShare.delete_directory(s, p) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:list_dir, s, d} ->
        case Smalt.DataPlane.FileShare.list_dir(s, d, qp["prefix"]) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:create_file, s, p} ->
        case Smalt.DataPlane.FileShare.create_file(s, p, headers) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:put_range, s, p} ->
        # KD-COVERS: KD-175 (EXPL-9 F2) — the read_body match was unguarded:
        # a >8MB body returned {:more, _, _}, the MatchError escaped the
        # router (no crash-path fence existed), and Bandit rendered a NAKED
        # adapter 500 (empty body, no envelope, no x-ms-request-id). Real
        # Azure answers typed 413 RequestBodyTooLarge; the case below is the
        # canonical blob_block_arm shape (egress_router.ex ~2549).
        case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
          {:ok, body, _conn} ->
            case Smalt.DataPlane.FileShare.put_range(s, p, headers, body) do
              {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
              {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
            end

          {:more, partial, _conn} ->
            send_file_error(conn, 413, "RequestBodyTooLarge", file_range_too_large_msg(partial))

          {:error, reason} ->
            send_file_error(conn, 400, "InvalidRequestBody", inspect(reason))
        end

      {:get_range_list, s, p} ->
        case Smalt.DataPlane.FileShare.get_range_list(s, p) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_file, s, p} ->
        # w6R disclosed unblock (share-existence gate): without it the 3+seg
        # GET/DELETE catch-alls swallow blob-plane requests for absent shares.
        # Absent share -> conn unchanged -> falls through to the blob splat.
        case Smalt.DataPlane.FileShare.get_share_properties(s) do
          {:error, 404, _c, _m} ->
            conn

          _ ->
            case Smalt.DataPlane.FileShare.get_file(s, p, headers) do
              {:ok, st, h, b} -> send_file_bytes(conn, st, h, b)
              {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
            end
        end

      {:delete_file, s, p} ->
        case Smalt.DataPlane.FileShare.get_share_properties(s) do
          {:error, 404, _c, _m} ->
            conn

          _ ->
            case Smalt.DataPlane.FileShare.delete_file(s, p) do
              {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
              {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
            end
        end
    end
  end

  def send_file_xml(conn, st, h, b) do
    conn
    |> put_resp_headers(h)
    |> put_resp_content_type("application/xml")
    |> send_resp(st, b || "")
  end

  def send_file_bytes(conn, st, h, b) do
    conn
    |> put_resp_headers(h)
    |> send_resp(st, b)
  end

  def send_file_headers_only(conn, st, h) do
    conn
    |> put_resp_headers(h)
    |> send_resp(st, "")
  end

  # EXPL-9 F2 (KD-COVERS: KD-175): oversized Put Range body message.
  defp file_range_too_large_msg(partial) do
    "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes)."
  end

  def send_file_error(conn, st, code, msg) do
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-06-08")
    |> put_resp_header("x-ms-error-code", code)
    |> put_resp_content_type("application/xml")
    |> send_resp(st, error_xml(code, msg))
  end

  # ---------------------------------------------------------------------------
  # G5 tenant fence (RESTORED from the pre-undock source 95d4243d — coordinator
  # scope addendum for this lane; the undock dropped the whole fence and the
  # blob/queue legs of tenant_fence_blob_kv_queue_test were red). Mounted in
  # the front pipeline downstream of Smalt.Auth.Bearer so resolve_tenant/1
  # reads the verified bearer; home/no-tid bearers pass through byte-identical
  # (legacy law).
  # ---------------------------------------------------------------------------
  # G5 tenant fence plug (CZ2 law; shared helper Smalt.Auth.TenantLaw).
  # Foreign-`tid` bearers on the blob/queue planes get (a) their account
  # segment namespaced via TenantLaw.tenant_scoped_key/2 so tenant data is
  # structurally partitioned, and (b) point access at a key that exists only
  # under another tenant's namespace answered with the typed 403 (never a
  # 404 lie, never a silent leak). Home/no-tid bearers pass through
  # byte-identical — every legacy single-tenant court keeps its exact wire.
  # ---------------------------------------------------------------------------
  def tenant_namespace(conn, _opts \\ nil) do
    tenant = Smalt.Auth.TenantLaw.resolve_tenant(conn)

    if tenant == Smalt.Auth.TenantLaw.home_tenant() do
      conn
    else
      cond do
        queue_plane_shape?(conn) -> tenant_queue_fence(conn, tenant)
        tenant_blob_shape?(conn) -> tenant_blob_fence(conn, tenant)
        true -> conn
      end
    end
  end

  # Blob-fence scope: blob-plane heuristic + NOT a reserved/service segment
  # (@tenant_reserved_first_segments — the 95d4243d fence list, WITH v1.0;
  # see the moduledoc rename note) routes are matched before the blob splat
  # and must never see a rewritten path) + NOT an auth-exempt bootstrap path
  # (STS mint/discovery must stay reachable for foreign-tenant clients).
  @tenant_reserved_first_segments ~w(dbs secrets certificates keys topics subscriptions attest app atlas dataCollectionRules v1 v1.0 providers)

  defp tenant_blob_shape?(conn) do
    first = conn.path_info |> List.first()

    blob_plane_path?(conn.request_path) and
      first not in @tenant_reserved_first_segments and
      first != "tables" and
      not Smalt.Auth.Bearer.auth_exempt_path?(conn.request_path)
  end

  defp tenant_queue_fence(conn, tenant) do
    case conn.path_info do
      [account, queue | _] ->
        qkey = String.downcase("#{account}/#{queue}")

        if foreign_scoped_key?(:smalt_q_queues, tenant, qkey) do
          refuse_tenant_403(conn)
        else
          namespace_account(conn, tenant, account)
        end

      [_account] ->
        # List Queues: no point key — namespacing alone yields the empty
        # feed for a tenant with no own rows (never a 403).
        namespace_account(conn, tenant, hd(conn.path_info))
    end
  end

  defp tenant_blob_fence(conn, tenant) do
    case conn.path_info do
      [account, container | _] ->
        ckey = "#{account}/#{container}"

        if foreign_scoped_key?(:smalt_blob_containers, tenant, ckey) do
          refuse_tenant_403(conn)
        else
          namespace_account(conn, tenant, account)
        end

      [_account] ->
        # List Containers / service properties: namespacing alone.
        namespace_account(conn, tenant, hd(conn.path_info))
    end
  end

  # Rewrite the account segment so every downstream engine key is derived in
  # the caller's namespace ("{tenant}/{account}/..."); home callers never get
  # here, so legacy keys stay byte-identical.
  defp namespace_account(conn, tenant, account) do
    scoped = Smalt.Auth.TenantLaw.tenant_scoped_key(tenant, account)
    segs = [scoped | tl(conn.path_info)]
    path = "/" <> Enum.join(segs, "/")

    conn
    |> Map.put(:path_info, segs)
    |> Map.put(:request_path, path)
  end

  # True when `legacy_key` exists in `table` ONLY under a namespace that is
  # NOT `tenant`'s: the exact legacy (home) key itself, or a
  # "{other_tenant}/.../legacy_key" scoped key with the tenant prefix
  # (everything before the exact "/#{legacy_key}" suffix) different from
  # `tenant`. Real Store.keys/1 scan — no mocks.
  def foreign_scoped_key?(table, tenant, legacy_key) do
    own = Smalt.Auth.TenantLaw.tenant_scoped_key(tenant, legacy_key)

    Enum.any?(Store.keys(table), fn k ->
      is_binary(k) and k != own and
        (k == legacy_key or foreign_prefixed_key?(k, legacy_key, tenant))
    end)
  end

  defp foreign_prefixed_key?(k, legacy_key, tenant) do
    if String.ends_with?(k, "/#{legacy_key}") do
      binary_part(k, 0, byte_size(k) - byte_size(legacy_key) - 1) != tenant
    else
      false
    end
  end

  # Typed 403 — the TenantLaw Forbidden envelope, rendered through the same
  # blob_error face the planes already use (XML on the blob face, JSON
  # envelope on queue shapes).
  defp refuse_tenant_403(conn) do
    blob_error(conn, 403, %{
      "error" => %{
        "code" => "Forbidden",
        "message" => Smalt.Auth.TenantLaw.mismatch_message()
      }
    })
  end

  # G5: public read — the tenant fence plug consumes the canonical shape
  # predicate (one law, never a copied shape list).
  def queue_plane_shape?(conn) do
    qp = fetchd_query_params(conn)

    case conn.path_info do
      [_account] -> qp["restype"] == "queue" and qp["comp"] == "list"
      [_account, _queue] -> qp["restype"] == "queue"
      [_account, _queue, "messages"] -> true
      [_account, _queue, "messages", _id] -> true
      _ -> false
    end
  end

  # Blob-plane path heuristic: blob REST is /{account}[/{container}[/{blob}]]
  # with no leading plane prefix (kv/cosmos/appconfig/attest/messaging...).
  # G5: public read of the blob-plane heuristic — the tenant fence plug
  # consumes it (one canonical predicate, never a copied prefix list).
  def blob_plane_path?("/" <> rest) do
    first = rest |> String.split("/", parts: 2) |> hd()

    first not in [
      "keys",
      "secrets",
      "certificates",
      "certificates/",
      # BK-56: deletedcertificates is the certs plane's soft-delete surface
      # (popcorn_demo LiveCerts deleted-get leg), never a blob account.
      "deletedcertificates",
      "kv",
      "dbs",
      "attest",
      "snapshots",
      "segments",
      "subscriptions",
      "metadata",
      "v2",
      "schemas",
      "revisions",
      "managedstorage",
      "$schemagroups",
      # PRD-APIM wire: /apim-gw is a policy-chained gateway namespace, never a
      # blob account (the apim plug intercepts configured gateways; the
      # unconfigured/default-off face is owned by the apim plane below).
      "apim-gw",
      # BK-SKIPPORT: /topics is the EventGrid publish/readback plane
      # (Microsoft.EventGrid systemTopics -> /topics/:topic/events); the blob
      # heuristic shadowed it as a phantom blob account, so topic OPTIONS
      # preflights were 403'd against account "topics" rules (always empty).
      "topics",
      # AZURE-FIDELITY lane 13/AF-L14-GAP-1 (v26.10.25): /v1.0/* is the
      # Microsoft Graph stub surface (servicePrincipals/applications/
      # oauth2PermissionGrants/auditLogs/signIns) — never a blob account; the
      # tenant fence must not namespace its account segment (witnessed:
      # foreign-tid bearer -> account "v1.0" namespaced -> GraphRoutes
      # fallthrough -> blob 400 MissingXMsVersion, signins court 0/3).
      "v1.0"
    ]
  end

  def blob_plane_path?(_), do: false

  # ---------------------------------------------------------------------------
  # Immutable Blob Storage REST API — guarded catch-all
  # NOTE route ordering: GET /{account}?comp=list is a single-segment route and
  # must be defined BEFORE the generic /:account/:container catch-alls below.
  # ---------------------------------------------------------------------------
  get "/:account" do
    cond do
      # Parity lane 2026-10-28 (receipted vs Azurite): Get Blob Service
      # Properties (restype=service&comp=properties). Static defaults — the
      # @azure/storage-blob SDK parses Logging/Cors out of this XML.
      conn.query_params["restype"] == "service" and conn.query_params["comp"] == "properties" ->
        conn
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-version", "2021-12-02")
        |> put_resp_content_type("application/xml")
        |> send_resp(
          200,
          "<?xml version=\"1.0\" encoding=\"utf-8\"?><StorageServiceProperties>" <>
            "<Logging><Version>1.0</Version><Read>false</Read><Write>false</Write><Delete>false</Delete>" <>
            "<RetentionPolicy><Enabled>false</Enabled></RetentionPolicy></Logging>" <>
            "<HourMetrics><Version>1.0</Version><Enabled>false</Enabled>" <>
            "<RetentionPolicy><Enabled>false</Enabled></RetentionPolicy></HourMetrics>" <>
            "<MinuteMetrics><Version>1.0</Version><Enabled>false</Enabled>" <>
            "<RetentionPolicy><Enabled>false</Enabled></RetentionPolicy></MinuteMetrics>" <>
            "<Cors></Cors>" <>
            "</StorageServiceProperties>"
        )

      conn.query_params["comp"] == "list" ->
        blob_route(conn, fn conn ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            # Typed engine errors (container-list maxresults 400,
            # v26.10.14 lane 06 defects 2+3) reach the wire as the Azure XML
            # <Error> envelope on this comp=list route — never a MatchError 500
            # or a JSON body where the real service emits XML.
            case BlobService.list_containers_xml(account, %{
                   "prefix" => conn.query_params["prefix"],
                   "marker" => conn.query_params["marker"],
                   "maxresults" => conn.query_params["maxresults"]
                 }) do
              {xml, _next_marker} ->
                conn
                |> put_resp_content_type("application/xml")
                |> send_resp(200, xml)

              {:error, status, code, msg} when is_integer(status) ->
                blob_error_xml(conn, status, code, msg)
            end
          end
        end)

      true ->
        blob_error(conn, 404, %{
          "error" => %{
            "code" => "RouteNotFound",
            "message" => "No route matches #{conn.method} #{conn.request_path}"
          }
        })
    end
  end

  # w6av: Set Blob Service Properties (?restype=service&comp=properties) —
  # parses the StaticWebsite block into the per-account props ETS. 202 per
  # Azure Set Service Properties parity. Must precede the blob splat.
  # (re-landed from the pre-undock source 95d4243d — the undock dropped the
  # PUT arm while expl9r1 F4 kept pinning the 413/typed-body law)
  put "/:account" do
    if conn.query_params["restype"] == "service" and conn.query_params["comp"] == "properties" do
      blob_route(conn, fn conn ->
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          # EXPL-9 F4 (KD-COVERS: KD-175) — same unguarded read_body escape as
          # the put_range arm; behind the x-ms-version fence, so reaching it
          # needs a valid version header + >8MB body. Same canonical guard.
          case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
            {:ok, body, conn} ->
              case BlobStorage.set_service_properties(account, body) do
                :ok ->
                  # w6ay: parse + store the <Cors> rules from the same PUT body
                  # (parity: PUT without a Cors block clears rules).
                  case Smalt.DataPlane.BlobCors.parse_cors_xml(body) do
                    {:error, s, c, m} ->
                      blob_error(conn, s, not_found_error(c) |> put_message(m))

                    rules when is_list(rules) ->
                      case Smalt.DataPlane.BlobCors.put_rules(account, rules) do
                        :ok ->
                          conn
                          |> put_resp_header("x-ms-request-id", generate_request_id())
                          |> put_resp_header("x-ms-version", "2021-12-02")
                          |> send_resp(202, "")

                        {:error, s, c, m} ->
                          blob_error(conn, s, not_found_error(c) |> put_message(m))
                      end
                  end

                {:error, status, code, msg} ->
                  blob_error(conn, status, not_found_error(code) |> put_message(msg))
              end

            {:more, partial, _conn} ->
              blob_error(conn, 413, %{
                "error" => %{
                  "code" => "RequestBodyTooLarge",
                  "message" =>
                    "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes)."
                }
              })

            {:error, reason} ->
              blob_error(conn, 400, %{
                "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
              })
          end
        end
      end)
    else
      blob_error(conn, 404, %{
        "error" => %{
          "code" => "RouteNotFound",
          "message" => "No route matches #{conn.method} #{conn.request_path}"
        }
      })
    end
  end

  put "/:account/:container" do
    blob_route(conn, fn conn ->
      cond do
        # R98 fail-closed container comp registration: an unknown comp on the
        # container PUT arm is a typed 400, never a silent 201 create.
        unhandled_comp?(conn, @container_put_comps) ->
          unhandled_container_comp_error(conn, conn.query_params["comp"])

        # KD-108: container lease surface (acquire/renew/release/break via
        # x-ms-lease-action). Engine: BlobStorage.lease_container/5 — state
        # rides the container row map; active lease refuses Delete Container
        # 409 ContainerLeased in BlobStorage.delete_container/3.
        conn.query_params["comp"] == "lease" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.lease_container(
                   account,
                   container,
                   header_map(conn)["x-ms-lease-action"],
                   header_map(conn)
                 ) do
              {:ok, status, headers, _record} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        # KD-108: container ACL / signed identifiers. PUT -> 204 No Content;
        # GET -> 200 SignedIdentifiers XML (BlobStorage.acl_xml/1).
        conn.query_params["comp"] == "acl" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case acl_body(conn) do
              {:ok, body, conn} ->
                case BlobStorage.set_container_acl(account, container, body, header_map(conn)) do
                  {:ok, status, headers, _record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> send_resp(status, "")

                  {:error, status, code, msg} ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] == "legalhold" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            flag = header_map(conn)["x-ms-legal-hold"] == "true"

            case BlobStorage.set_legal_hold(account, container, flag, header_map(conn)) do
              {:ok, status, headers, record} ->
                conn
                |> put_resp_headers(headers)
                |> put_resp_content_type("application/json")
                |> send_resp(status, Jason.encode!(record))

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] in ["immutabilityPolicy", "immutabilitypolicy"] ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case immutability_policy_from_wire(conn) do
              {:ok, policy, conn} ->
                case BlobStorage.set_immutability_policy(
                       account,
                       container,
                       policy,
                       header_map(conn)
                     ) do
                  {:ok, status, headers, record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> put_resp_content_type("application/json")
                    |> send_resp(status, Jason.encode!(record))

                  {:error, status, code, msg} ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end

              {:error, conn} ->
                blob_error(conn, 400, %{
                  "error" => %{
                    "code" => "InvalidXmlOrJson",
                    "message" => "The immutability policy body is not valid XML or JSON."
                  }
                })
            end
          end

        conn.query_params["comp"] == "metadata" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.set_container_metadata(account, container, meta_headers(conn)) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          opts = %{"immutable" => get_req_header(conn, "x-ms-immutable-policy") != ["false"]}

          # Azure parity: x-ms-meta-* on Put Container SETS metadata at
          # create. Validated BEFORE the create — a refused create must not
          # leave the container behind.
          with :ok <- BlobService.check_metadata(meta_headers(conn)) do
            case BlobStorage.create_container(account, container, opts) do
              {:ok, record} ->
                # R77: propagate the create-time seeding result. The container
                # stands either way (Azure parity: create is not rolled back),
                # but a refused/failed seeding is logged loudly, never silently
                # dropped — a fresh no-policy container must seed (R62's gate
                # does not block it); only hold/locked refusals may skip it.
                case BlobService.set_container_metadata(account, container, meta_headers(conn)) do
                  {:ok, 200, _} ->
                    :ok

                  {:error, _status, _code, _msg} = seeding ->
                    require Logger

                    Logger.warning(
                      "container created but x-ms-meta-* seeding did not land: #{inspect(seeding)} (SHIM-COURT R77)"
                    )
                end

                # Real Azure (lens-5 work order, cycle-33): 201 create carries
                # a quoted ETag, RFC 1123 Last-Modified, x-ms-request-id +
                # x-ms-version, and an EMPTY body. GET properties is
                # untouched (courts pin its exact bytes).
                {:ok, created_dt, _} = DateTime.from_iso8601(record["created"])

                conn
                |> put_resp_header("etag", container_put_etag(record))
                |> put_resp_header(
                  "last-modified",
                  Calendar.strftime(created_dt, "%a, %d %b %Y %H:%M:%S GMT")
                )
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> send_resp(201, "")

              # Idempotent Put Container (real Azure semantics): re-PUT on an
              # EXISTING container is 200 with the standard headers when the
              # x-ms-meta-* set is IDENTICAL, 409 ContainerAlreadyExists when
              # it differs. The WORM/lease gates stay AHEAD of the comparison
              # (container_reput_arm) — a hold/locked re-PUT still refuses
              # 409 ContainerLocked per the WORM arms.
              {:error, 409, "ContainerAlreadyExists", _msg} ->
                container_reput_arm(conn, account, container)

              # Cross-lane repair (blob lane cycle-15 §3): typed engine error
              # tuples `{:error, status, code, msg}` from create_container
              # reach the wire at their exact Azure status instead of a
              # blanket 500 — this un-deads blob's container-name-grammar and
              # duplicate-create-409 fences. Non-tuple shapes keep the
              # runtime safety net below.
              {:error, status, code, msg} when is_integer(status) ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))

              # mechanical warning fix (store+graphlaw lane): the compiler types
              # create_container/3 as {:ok, map()} only (no error clauses in the
              # data plane), so the shape is not statically indexable; the dead
              # branch stays as a runtime safety net without elem/2 indexing.
              other ->
                blob_error(conn, 500, %{"error" => inspect(other)})
            end
          else
            {:error, status, code, msg} ->
              blob_error(conn, status, not_found_error(code) |> put_message(msg))
          end
      end
    end)
  end

  # Idempotent Put Container arm (see the 409 ContainerAlreadyExists clause
  # in the create route): WORM/lease gate FIRST (hold or locked-while-retention-
  # live → 409 ContainerLocked, mirroring BlobService.check_metadata_worm
  # semantics via BlobStorage.policy_state/3), then metadata comparison —
  # IDENTICAL x-ms-meta-* → 200 with the standard headers; DIFFERENT →
  # 409 ContainerAlreadyExists.
  defp container_reput_arm(conn, account, container) do
    requested = meta_headers(conn)

    case BlobStorage.policy_state(account, container) do
      {:ok, %{"legal_hold" => true}} ->
        blob_error(conn, 409, %{
          "error" => %{
            "code" => "ContainerLocked",
            "message" =>
              "Blob modification refused: container has an active legal hold (ContainerLocked)."
          }
        })

      {:ok, %{"locked" => true, "expired" => false}} ->
        blob_error(conn, 409, %{
          "error" => %{
            "code" => "ContainerLocked",
            "message" =>
              "Blob modification refused: container has a locked immutability policy (ContainerLocked)."
          }
        })

      {:ok, _state} ->
        existing =
          case BlobStorage.get_policy(account, container) do
            nil -> %{}
            policy -> Map.get(policy, "metadata") || %{}
          end

        if existing == requested do
          {:ok, record} = Store.get(:smalt_blob_containers, "#{account}/#{container}")
          {:ok, created_dt, _} = DateTime.from_iso8601(record["created"])

          conn
          |> put_resp_header("etag", container_put_etag(record))
          |> put_resp_header(
            "last-modified",
            Calendar.strftime(created_dt, "%a, %d %b %Y %H:%M:%S GMT")
          )
          |> put_resp_header("x-ms-request-id", generate_request_id())
          |> put_resp_header("x-ms-version", "2021-12-02")
          |> send_resp(200, "")
        else
          blob_error(conn, 409, %{
            "error" => %{
              "code" => "ContainerAlreadyExists",
              "message" => "The specified container already exists with different metadata."
            }
          })
        end

      {:error, :container_not_found} ->
        blob_error(conn, 404, %{
          "error" => %{"code" => "ContainerNotFound", "message" => "Container not found."}
        })
    end
  end

  get "/:account/:container" do
    blob_route(conn, fn conn ->
      cond do
        # R98 fail-closed container comp registration: an unknown comp on the
        # container GET arm is a typed 400, never a wrong-body 200.
        unhandled_comp?(conn, @container_get_comps) ->
          unhandled_container_comp_error(conn, conn.query_params["comp"])

        conn.query_params["comp"] in ["immutabilityPolicy", "immutabilitypolicy"] ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_policy(account, container) do
              %{"immutability_policy" => policy} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(policy))

              _ ->
                blob_error(conn, 404, not_found_error("ImmutabilityPolicyNotFound"))
            end
          end

        conn.query_params["comp"] == "legalhold" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_policy(account, container) do
              %{"legal_hold" => flag} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_header("x-ms-legal-hold", to_string(flag))
                |> send_resp(200, "")

              _ ->
                blob_error(conn, 404, not_found_error("LegalHoldNotFound"))
            end
          end

        # KD-108: Get Container ACL — 200 SignedIdentifiers XML.
        conn.query_params["comp"] == "acl" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_acl(account, container) do
              {:ok, identifiers} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_content_type("application/xml")
                |> send_resp(200, BlobStorage.acl_xml(identifiers))

              {:error, :container_not_found} ->
                blob_error(conn, 404, %{
                  "error" => %{"code" => "ContainerNotFound", "message" => "Container not found."}
                })
            end
          end

        conn.query_params["comp"] == "metadata" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.get_container_metadata(account, container) do
              {:ok, meta} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_headers(meta_headers(meta))
                |> send_resp(200, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] == "list" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            # Typed engine errors (e.g. blob lane's pending maxresults 400)
            # must reach the wire at their exact status — a bare
            # {xml, _} destructure here would MatchError into a blanket 500.
            case BlobStorage.list_blobs_xml(account, container, %{
                   "prefix" => conn.query_params["prefix"],
                   "delimiter" => conn.query_params["delimiter"],
                   "include" => conn.query_params["include"],
                   "marker" => conn.query_params["marker"],
                   "maxresults" => conn.query_params["maxresults"]
                 }) do
              {xml, _next_marker} ->
                conn
                |> put_resp_content_type("application/xml")
                |> send_resp(200, xml)

              # comp=list errors emit the Azure XML <Error> envelope on the
              # blob list route (real-service shape; lane 06 defect 3).
              {:error, status, code, msg} when is_integer(status) ->
                blob_error_xml(conn, status, code, msg)
            end
          end

        conn.query_params["restype"] == "container" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.get_container_properties(account, container) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          case BlobStorage.list_blobs_xml(account, container, %{
                 "prefix" => conn.query_params["prefix"],
                 "delimiter" => conn.query_params["delimiter"],
                 "include" => conn.query_params["include"],
                 "marker" => conn.query_params["marker"],
                 "maxresults" => conn.query_params["maxresults"]
               }) do
            {xml, _next_marker} ->
              conn
              |> put_resp_content_type("application/xml")
              |> send_resp(200, xml)

            # comp=list-class errors emit the Azure XML envelope here too
            # (lane 06 defect 3; the plain-GET container fallback is the same
            # list operation as the comp=list arm).
            {:error, status, code, msg} when is_integer(status) ->
              blob_error_xml(conn, status, code, msg)
          end
      end
    end)
  end

  put "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # KD-108 (blob lane remainder): snapshot lease wire arm —
      # PUT ?comp=lease&sharesnapshot=<ts> with x-ms-lease-action rides the
      # FROZEN snapshot record (BlobStorage.lease_blob_snapshot/6, per-snapshot
      # lease id namespace). Runs BEFORE the fail-closed comp registration so
      # the implemented pair (comp=lease AND sharesnapshot) is never eaten by
      # the 400 default-deny; comp=lease WITHOUT sharesnapshot stays
      # default-deny (400 GAP) until the base-blob lease surface registers.
      if conn.query_params["comp"] == "lease" and
           conn.query_params["sharesnapshot"] not in [nil, ""] do
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          case BlobStorage.lease_blob_snapshot(
                 account,
                 container,
                 blob_name,
                 conn.query_params["sharesnapshot"],
                 header_map(conn)["x-ms-lease-action"],
                 header_map(conn)
               ) do
            {:ok, status, headers, _record} ->
              conn
              |> put_resp_headers(headers)
              |> send_resp(status, "")

            {:error, status, code, msg} ->
              blob_error(conn, status, not_found_error(code) |> put_message(msg))
          end
        end
      else
      # GAP-AUD1-01 (v26.10.14, lane W-5): fail-closed comp registration on the
      # blob PUT arm. Any comp value with no implemented handler here (snapshot,
      # page, tags, query, tier, expiry, seal, lease, copy, ...) previously fell
      # into the generic Put Blob fallback and stored the request's (usually
      # empty) body AS THE BLOB BODY — the audit's headline corruption class.
      # Known comps route to their handlers; every OTHER comp answers a typed
      # 400 and never reaches read_body/put_blob.
      if unhandled_comp?(conn, @blob_put_comps) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        # X-1 (v26.10.14): Put Block / Put Block List get dedicated arms BEFORE
        # the generic Put Blob fallback — previously comp=blocklist fell into
        # put_blob and stored the request XML as the blob body (P0 data
        # corruption found by bench B-5).
        if conn.query_params["comp"] in ["block", "blocklist"] do
          blob_block_arm(conn, account, container, blob_name)
        else
          # KD-01 wire normalization (Azure Put Blob Metadata): comp=metadata is
          # answered BEFORE the body read — 200 EMPTY with etag, never the old
          # 201 + JSON debug body (which also silently emptied the content).
          if conn.query_params["comp"] == "metadata" do
            if not_ready?(conn, [BlobStorage]) do
              route_not_ready(conn)
            else
              case BlobStorage.set_blob_metadata(
                     account,
                     container,
                     blob_name,
                     meta_headers(conn)
                   ) do
                {:ok, status, headers} ->
                  send_headers(conn, status, headers)

                # SHIM-COURT: metadata PUT under WORM hold/locked policy -> 409
                # ContainerLocked (R183 finding 2; keep in lockstep with the
                # put_blob / commit_block_list arms above).
                {:error, :worm_locked, msg} ->
                  blob_error(conn, 409, %{
                    "error" => %{"code" => "ContainerLocked", "message" => msg}
                  })

                {:error, status, code, msg} ->
                  blob_error(conn, status, not_found_error(code) |> put_message(msg))
              end
            end
          else
            # KD-COVERS: KD-60 — Snapshot Blob wire arm (KD-52's engine
            # snapshot_blob/5 was previously engine-only; an unregistered comp hit
            # the typed 400). Azure answers 201 with the x-ms-snapshot timestamp
            # header; the engine handles existence + WORM (legal hold blocks the
            # snapshot create arm with 409 ContainerLocked).
            if conn.query_params["comp"] == "snapshot" do
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case BlobStorage.snapshot_blob(account, container, blob_name, header_map(conn)) do
                  {:ok, 201, headers, nil} ->
                    send_headers(conn, 201, headers)

                  # WORM create arm: legal hold (or locked policy) -> 409
                  # ContainerLocked, same shape as the metadata/put_blob arms.
                  {:error, 409, "ContainerLocked", msg} ->
                    blob_error(conn, 409, %{
                      "error" => %{"code" => "ContainerLocked", "message" => msg}
                    })

                  {:error, status, code, msg} when is_integer(status) ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end
              end
            else
            # Parity lane 2026-10-28: base-blob lease (comp=lease WITHOUT
            # sharesnapshot; the snapshot variant is handled above). Header-only
            # request — no body read. x-ms-lease-action drives the state machine.
            if conn.query_params["comp"] == "lease" do
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case BlobStorage.lease_blob(
                       account,
                       container,
                       blob_name,
                       header_map(conn)["x-ms-lease-action"],
                       header_map(conn)
                     ) do
                  {:ok, status, headers, _record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> send_resp(status, "")

                  {:error, status, code, msg} ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end
              end
            else
            # Parity lane 2026-10-28: Set Blob HTTP Headers (comp=properties).
            # Header-only request — no body read. 200 with the rotated etag.
            if conn.query_params["comp"] == "properties" do
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case BlobStorage.set_blob_http_headers(account, container, blob_name, header_map(conn)) do
                  {:ok, status, headers, _record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> send_resp(status, "")

                  {:error, status, code, msg} ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end
              end
            else
            # Parity lane 2026-10-28: Append Block (comp=appendblock) and Put
            # Page (comp=page) — body-carrying writes through the same
            # read_body discipline as the generic Put Blob fallback.
            if conn.query_params["comp"] in ["appendblock", "page"] do
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
                  {:ok, body, _conn} ->
                    if conn.query_params["comp"] == "appendblock" do
                      case BlobStorage.append_block(account, container, blob_name, body, header_map(conn)) do
                        {:ok, status, headers, _record} ->
                          conn |> put_resp_headers(headers) |> send_resp(status, "")

                        {:error, :worm_locked, _nil, msg} ->
                          blob_error(conn, 409, %{
                            "error" => %{"code" => "ContainerLocked", "message" => msg}
                          })

                        {:error, status, code, msg} ->
                          blob_error(conn, status, not_found_error(code) |> put_message(msg))
                      end
                    else
                      case BlobStorage.put_page(account, container, blob_name, body, header_map(conn)) do
                        {:ok, status, headers, _record} ->
                          conn |> put_resp_headers(headers) |> send_resp(status, "")

                        {:error, :worm_locked, _nil, msg} ->
                          blob_error(conn, 409, %{
                            "error" => %{"code" => "ContainerLocked", "message" => msg}
                          })

                        {:error, status, code, msg} ->
                          blob_error(conn, status, not_found_error(code) |> put_message(msg))
                      end
                    end

                  {:more, partial, _conn} ->
                    blob_error(conn, 413, %{
                      "error" => %{
                        "code" => "RequestBodyTooLarge",
                        "message" =>
                          "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes)."
                      }
                    })

                  {:error, reason} ->
                    blob_error(conn, 400, %{
                      "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
                    })
                end
              end
            else
              case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
                {:ok, raw_body, conn} ->
                  case BlobStorage.put_blob(
                         account,
                         container,
                         blob_name,
                         raw_body,
                         header_map(conn)
                       ) do
                    {:ok, blob} ->
                      # Metadata-only body: raw "content" (arbitrary bytes, frequently
                      # invalid UTF-8) must never reach Jason — a metadata projection
                      # is total over binary content.
                      conn
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_content_type("application/json")
                      |> send_resp(201, Jason.encode!(BlobStorage.blob_metadata(blob)))

                    {:error, :worm_locked, msg} ->
                      blob_error(conn, 409, %{
                        "error" => %{"code" => "ContainerLocked", "message" => msg}
                      })

                    {:error, :precondition_failed, msg} ->
                      blob_error(conn, 412, %{
                        "error" => %{"code" => "PreconditionFailed", "message" => msg}
                      })

                    {:error, :too_large, msg} ->
                      blob_error(conn, 413, %{
                        "error" => %{"code" => "RequestBodyTooLarge", "message" => msg}
                      })

                    {:error, :container_not_found} ->
                      blob_error(conn, 404, not_found_error("ContainerNotFound"))

                    {:error, status, code, msg} when is_integer(status) ->
                      # engine-emitted typed HTTP errors (e.g. 400 InvalidMetadata)
                      blob_error(conn, status, not_found_error(code) |> put_message(msg))
                  end

                # A partial read is oversize only when it fills the cap; a small
                # partial means the body was truncated mid-flight (transport stopped
                # early) — Plug.Conn.read_body is single-shot, so {:more, small, _}
                # is a truncation, not a size refusal. Measured with a real
                # partial-then-error adapter (egress cycle-8).
                {:more, partial, _conn} when byte_size(partial) >= 8_000_000 ->
                  blob_error(conn, 413, %{
                    "error" => %{
                      "code" => "RequestBodyTooLarge",
                      "message" => "Blob exceeds the 8,000,000-byte request body limit."
                    }
                  })

                {:more, partial, _conn} ->
                  blob_error(conn, 400, %{
                    "error" => %{
                      "code" => "InvalidRequestBody",
                      "message" =>
                        "The request body was truncated mid-flight " <>
                          "(read #{byte_size(partial)} of the declared bytes)."
                    }
                  })

                # Plug >= 1.14 read_body returns {:error, reason} without the conn; the
                # historical {:error, term, _conn} clause here was typed-unreachable.
                {:error, reason} ->
                  blob_error(conn, 400, %{
                    "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
                  })
              end
            end
            end
            end
            end
          end
        end
      end
      end
    end)
  end

  get "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # GAP-AUD1-01 (v26.10.14, lane W-5): same fail-closed comp registration
      # on the GET arm — comp=pagelist/tags previously fell past the blocklist
      # branch and served blob CONTENT with a 200 (SDK XML decode error /
      # silent wrong semantics).
      if unhandled_comp?(conn, @blob_get_comps) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        # KD-COVERS: KD-60 — Get Blob Metadata (`GET ?comp=metadata`): 200 EMPTY
        # with the stored x-ms-meta-* headers echoed back, mirroring the PUT
        # comp=metadata arm's meta_headers/stored_meta_wire read path.
        if conn.query_params["comp"] == "metadata" do
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_blob(account, container, blob_name) do
              {:ok, blob} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> send_resp(200, "")

              :error ->
                blob_error(conn, 404, not_found_error("BlobNotFound"))
            end
          end
        else
          # X-1 (v26.10.14): Get Block List — Azure answers application/xml; the
          # old fallback served the blob body as octet-stream (SDK DecodeError).
          if conn.query_params["comp"] == "blocklist" do
            if not_ready?(conn, [BlobStorage]) do
              route_not_ready(conn)
            else
              case BlobStorage.get_block_list(account, container, blob_name) do
                {:ok, committed, uncommitted} ->
                  conn
                  |> put_resp_header("x-ms-request-id", generate_request_id())
                  |> put_resp_header("x-ms-version", "2021-12-02")
                  |> put_resp_content_type("application/xml")
                  |> send_resp(200, BlobStorage.block_list_xml(committed, uncommitted))

                :error ->
                  blob_error(conn, 404, not_found_error("BlobNotFound"))
              end
            end
          else
            # KD-COVERS: KD-60 — snapshot read-back (`GET ?sharesnapshot=<ts>`):
            # serves the frozen point-in-time record from :smalt_blob_snapshots
            # byte-exact; base-blob mutations after the snapshot stay invisible
            # through the snapshot. Without the param the normal GET path runs.
            if conn.query_params["sharesnapshot"] in [nil, ""] do
              # Azure storage semantics: the range rides `x-ms-range` (python/JS SDKs)
              # or the standard `Range` header; honor both. x-ms-range WINS when both
              # are present (Azure parity + C4 fence): the engine takes List.first.
              range_header = get_req_header(conn, "x-ms-range") ++ get_req_header(conn, "range")

              # Conditional read (Azure parity, cycle-30): If-Match / If-None-Match
              # evaluated before the range branch; RFC 7232 precedence (If-Match
              # first, 412; then If-None-Match, 304).
              case BlobStorage.get_blob_conditional(
                     account,
                     container,
                     blob_name,
                     header_map(conn)
                   ) do
                {:error, 412, code, msg} ->
                  blob_error(conn, 412, not_found_error(code) |> put_message(msg))

                {:not_modified, etag} ->
                  conn
                  |> put_resp_header("etag", etag)
                  |> put_resp_header("x-ms-request-id", generate_request_id())
                  |> put_resp_header("x-ms-version", "2021-12-02")
                  |> send_resp(304, "")

                :error ->
                  blob_error(conn, 404, not_found_error("BlobNotFound"))

                {:ok, _blob} ->
                  case BlobStorage.get_blob_range(account, container, blob_name, range_header) do
                    {:ok, blob, nil} ->
                      conn
                      |> put_resp_headers(stored_meta_wire(blob))
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_header(
                        "content-length",
                        blob["content"] |> byte_size() |> Integer.to_string()
                      )
                      |> put_resp_content_type(stored_content_type(blob))
                      |> send_resp(200, blob["content"])

                    {:ok, blob, {first, last}} ->
                      body = binary_part(blob["content"], first, last - first + 1)

                      conn
                      |> put_resp_headers(stored_meta_wire(blob))
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_header(
                        "content-range",
                        "bytes #{first}-#{last}/#{byte_size(blob["content"])}"
                      )
                      |> put_resp_header(
                        "content-length",
                        (last - first + 1) |> Integer.to_string()
                      )
                      |> put_resp_content_type(stored_content_type(blob))
                      |> send_resp(206, body)

                    {:error, :range_not_satisfiable, total} ->
                      conn
                      |> put_resp_header("content-range", "bytes */#{total}")
                      |> put_resp_content_type("application/json")
                      |> send_resp(
                        416,
                        Jason.encode!(%{
                          "error" => %{
                            "code" => "InvalidRange",
                            "message" =>
                              "The range specified is invalid for a blob of #{total} bytes."
                          }
                        })
                      )

                    :error ->
                      blob_error(conn, 404, not_found_error("BlobNotFound"))
                  end
              end
            else
              # Snapshot read arm (sharesnapshot present).
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case BlobStorage.get_blob_snapshot(
                       account,
                       container,
                       blob_name,
                       conn.query_params["sharesnapshot"]
                     ) do
                  {:ok, blob} ->
                    conn
                    |> put_resp_headers(stored_meta_wire(blob))
                    |> put_resp_header("etag", blob["etag"])
                     |> put_resp_header("x-ms-snapshot", conn.query_params["sharesnapshot"])
                     |> put_resp_header(
                       "content-length",
                       blob["content"] |> byte_size() |> Integer.to_string()
                     )
                     |> put_resp_content_type(stored_content_type(blob))
                     |> send_resp(200, blob["content"])

                  {:error, _status, _code, _msg} ->
                    blob_error(conn, 404, not_found_error("BlobNotFound"))
                end
              end
            end
          end
        end
      end
    end)
  end

  # HEAD container: header-only container properties (restype=container),
  # mirroring the GET container-properties branch.
  head "/:account/:container" do
    blob_route(conn, fn conn ->
      if conn.query_params["restype"] == "container" do
        if not_ready?(conn, [BlobService]) do
          route_not_ready(conn)
        else
          case BlobService.get_container_properties(account, container) do
            {:ok, status, headers} ->
              send_headers(conn, status, headers)

            {:error, status, code, msg} ->
              blob_error(conn, status, not_found_error(code) |> put_message(msg))
          end
        end
      else
        blob_error(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end

  # HEAD blob: same engine as GET, empty body, content-length set. This is what
  # @azure/storage-blob downloadToBuffer probes before it issues the GET.
  head "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # D14 (R122, KD-60): HEAD splat arm default-deny — comp=appendblock (and
      # any other unimplemented comp) previously served 200 header metadata as
      # if the operation had happened. SHIM-COURT: no HEAD blocklist handler
      # exists downstream, so unlike GET the whitelist must be EMPTY — a
      # comp=blocklist HEAD fell through to get_blob and served fake 200
      # header metadata. Same shape as the DELETE arm below.
      if unhandled_comp?(conn, []) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        # KD-COVERS: KD-97 — conditional/ranged HEAD parity (v26.10.17): the HEAD
        # arm previously dispatched to unconditional get_blob and answered 200 to
        # every conditional probe. Mirror the GET arm's engine (If-Match 412,
        # If-None-Match 304, Range 206/416) with empty bodies; content-length
        # still reflects the effective (range) size, as Azure parity requires.
        range_header = get_req_header(conn, "x-ms-range") ++ get_req_header(conn, "range")

        case BlobStorage.get_blob_conditional(account, container, blob_name, header_map(conn)) do
          {:error, 412, code, msg} ->
            blob_error(conn, 412, not_found_error(code) |> put_message(msg))

          {:not_modified, etag} ->
            conn
            |> put_resp_header("etag", etag)
            |> put_resp_header("x-ms-request-id", generate_request_id())
            |> put_resp_header("x-ms-version", "2021-12-02")
            |> send_resp(304, "")

          :error ->
            blob_error(conn, 404, not_found_error("BlobNotFound"))

          {:ok, _blob} ->
            case BlobStorage.get_blob_range(account, container, blob_name, range_header) do
              {:ok, blob, nil} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header(
                  "content-length",
                  blob["content"] |> byte_size() |> Integer.to_string()
                )
                |> put_resp_content_type(stored_content_type(blob))
                |> send_resp(200, "")

              {:ok, blob, {first, last}} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header(
                  "content-range",
                  "bytes #{first}-#{last}/#{byte_size(blob["content"])}"
                )
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header(
                  "content-length",
                  (last - first + 1) |> Integer.to_string()
                )
                |> put_resp_content_type(stored_content_type(blob))
                |> send_resp(206, "")

              {:error, :range_not_satisfiable, total} ->
                conn
                |> put_resp_header("content-range", "bytes */#{total}")
                |> put_resp_content_type("application/json")
                |> send_resp(
                  416,
                  Jason.encode!(%{
                    "error" => %{
                      "code" => "InvalidRange",
                      "message" => "The range specified is invalid for a blob of #{total} bytes."
                    }
                  })
                )

              :error ->
                blob_error(conn, 404, not_found_error("BlobNotFound"))
            end
        end
      end
    end)
  end

  delete "/:account/:container" do
    blob_route(conn, fn conn ->
      if unhandled_comp?(conn, []) do
        unhandled_container_comp_error(conn, conn.query_params["comp"])
      else
        case BlobStorage.delete_container(account, container, header_map(conn)) do
          {:ok, status, headers, _record} ->
            conn
            |> put_resp_headers(headers)
            |> send_resp(status, "")

          {:error, status, code, msg} ->
            blob_error(conn, status, not_found_error(code) |> put_message(msg))
        end
      end
    end)
  end

  delete "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # D14 (R122, KD-60): DELETE splat arm default-deny — no blob-level comp
      # has an implemented DELETE handler, so ANY comp (lease, appendblock,
      # snapshot, ...) previously fell through and deleted the blob anyway.
      # comp must be absent/empty; everything else is a typed 400.
      if unhandled_comp?(conn, []) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        case BlobStorage.delete_blob(account, container, blob_name, header_map(conn)) do
          {:ok, status, headers, _record} ->
            conn
            |> put_resp_headers(headers)
            |> send_resp(status, "")

          {:error, status, code, msg} ->
            blob_error(conn, status, not_found_error(code) |> put_message(msg))
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Blob Batch (GAP-AUD1-02): POST /{account}/{container}?comp=batch (container
  # level) and POST /{account}?comp=batch&restype=account (account level).
  # Multipart/mixed request body; each part's body is a full HTTP sub-request
  # (request line + headers [+ body]); each sub-request is dispatched to the
  # same BlobStorage engine as its individual route arm (delete / set tier).
  # Bounded at 256 sub-requests (real Azure's cap); over → 400.
  # ---------------------------------------------------------------------------
  post "/:account/:container" do
    blob_route(conn, fn conn ->
      if conn.query_params["comp"] == "batch" do
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          blob_batch_arm(conn, account)
        end
      else
        blob_error(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end

  post "/:account" do
    blob_route(conn, fn conn ->
      if conn.query_params["comp"] == "batch" do
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          blob_batch_arm(conn, account)
        end
      else
        blob_error(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end


  # X-1 (v26.10.14): Put Block / Put Block List wire arms. Put Block stages
  # raw block content (keyed account/container/blob/block-id); Put Block List
  # parses the request XML and commits the concatenation as the blob body.
  defp blob_block_arm(conn, account, container, blob_name) do
    if not_ready?(conn, [BlobStorage]) do
      route_not_ready(conn)
    else
      case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
        {:ok, body, _conn} ->
          if conn.query_params["comp"] == "block" do
            case BlobStorage.stage_block(
                   account,
                   container,
                   blob_name,
                   conn.query_params["blockid"] || "",
                   body,
                   header_map(conn)
                 ) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          else
            with {:ok, refs} <- BlobStorage.parse_block_list_xml(body),
                 {:ok, status, headers} <-
                   commit_response(account, container, blob_name, refs, header_map(conn)) do
              send_headers(conn, status, headers)
            else
              {:error, 400, code, msg} ->
                blob_error(conn, 400, not_found_error(code) |> put_message(msg))

              {:error, :worm_locked, msg} ->
                blob_error(conn, 409, %{
                  "error" => %{"code" => "ContainerLocked", "message" => msg}
                })

              {:error, :precondition_failed, msg} ->
                blob_error(conn, 412, %{
                  "error" => %{"code" => "PreconditionFailed", "message" => msg}
                })
            end
          end

        {:more, partial, _conn} ->
          blob_error(conn, 413, %{
            "error" => %{
              "code" => "RequestBodyTooLarge",
              "message" =>
                "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes)."
            }
          })

        {:error, reason} ->
          blob_error(conn, 400, %{
            "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
          })
      end
    end
  end

  # Map engine commit outcomes onto wire status/header tuples.
  defp commit_response(account, container, blob_name, refs, headers) do
    case BlobStorage.commit_block_list(account, container, blob_name, refs, headers) do
      {:ok, status, headers} -> {:ok, status, headers}
      {:error, :worm_locked, msg} -> {:error, :worm_locked, msg}
      {:error, :precondition_failed, msg} -> {:error, :precondition_failed, msg}
      {:error, status, code, msg} when is_integer(status) -> {:error, status, code, msg}
    end
  end

  # R99: known other-plane namespaces that must never reach the blob splat
  # arms (see reserved_fence_then below). Derived from
  # the router's documented route families (moduledoc).
  @reserved_first_segments ~w(dbs secrets certificates keys topics subscriptions attest app atlas dataCollectionRules v1 providers)

  # Blob catch-all guard: require x-ms-version header, or the host must be
  # configured in :smalt, :blob_catch_all_hosts.
  defp blob_route(conn, fun) do
    # B-XML (GAP(blob-error-envelope-json) close; re-landed from the pre-undock
    # source 95d4243d): stamp the blob face so blob_error/3 renders the Azure
    # Storage XML error envelope on this face only — ARM/Cosmos/KV/AppConfig/
    # Ledger consumers keep JSON byte-identical.
    conn = put_private(conn, :smalt_blob_face, true)

    # Auth-lens-5 disclosed unblock (test-freeze SLA): the slash-blob glob
    # `/:account/:container/*blob_name` widened the catch-all to 3+ segments,
    # so exempt-prefix traversals (…/oauth2/../../acct/cont/blob) now match
    # the blob routes and reach the 400 x-ms-version guard instead of the
    # 404/401 the auth traversal court pins. A decoded "."/".." SEGMENT is a
    # path-traversal shape, never a legal storage name; refuse 404
    # fail-closed before the version guard.
    # Decoded segments are split on "/" so %-encoded traversals
    # (%2f%2e%2e -> "/..") are caught component-wise; a slash-containing
    # blob name without "." / ".." components stays legal (slash-blob).
    if Enum.any?(conn.path_info, fn seg ->
         String.split(URI.decode(seg), "/") |> Enum.any?(&(&1 in [".", ".."]))
       end) do
      blob_error(conn, 404, not_found_error("BlobNotFound"))
    else
      # KD-97 rider (v26.10.17, C4 fence): stamp x-ms-request-id + x-ms-version
      # at blob-route entry so EVERY blob arm (success, XML, comp arms) carries
      # them — real Azure stamps request-id on all storage responses; the
      # success/XML arms previously shipped without either. Error arms
      # (blob_error/3) restamp their own; put_resp_header replaces, so the
      # values stay single-valued.
      conn =
        conn
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-version", "2021-12-02")

      # Auth-lens interplay (egress lens-4 cycle 1, measured): the auth-exempt
      # namespace (/.well-known/, /oauth2/, /attest/, /metadata/endpoints,
      # /{tid}/oauth2/v2.0/token) composes with the blob splat — account=
      # ".well-known"/"oauth2"/"attest"/"metadata" — and x-ms-version is
      # client-supplied, not authentication, so an UNAUTHENTICATED blob
      # CRUD surface was reachable inside the exempt namespace (measured at
      # this seam). Blob-reachable exempt paths are refused fail-closed here;
      # real discovery endpoints are served before the router ever sees a
      # blob route. Canonical predicate from Smalt.Auth.Bearer — never a
      # copied prefix list.
      auth_exempt_blob =
        Code.ensure_loaded?(Smalt.Auth.Bearer) and
          Smalt.Auth.Bearer.auth_exempt_path?(conn.request_path)

      if auth_exempt_blob do
        blob_error(conn, 404, not_found_error("BlobNotFound"))
      else
        blob_route_guarded(conn, fun)
      end
    end
  end

  defp blob_route_guarded(conn, fun) do
    allowed_hosts = Application.get_env(:smalt, :blob_catch_all_hosts, [])

    # GAP-AUD1-03 (v26.10.15, W-7): SAS query-token auth. A `sig=` query token
    # is admission evidence in its own right — a SAS-only URI (sig present, no
    # x-ms-version header) previously 400'd MissingXMsVersion and the SAS
    # flow was dead. Fail-closed: bad signature / no configured account key /
    # malformed token → 401 with the KD-15-enriched WWW-Authenticate challenge
    # class; live signature without the method's required permission → 403
    # AuthorizationPermissionMismatch; valid token → admitted with the SIGNED
    # permissions only.
    case Smalt.Auth.Sas.verify(conn) do
      {:ok, permissions} ->
        required = Smalt.Auth.Sas.required_permission(conn.method)

        if Smalt.Auth.Sas.authorized?(permissions, required) do
          # Tokened path: x-ms-version not required (GAP-AUD1-03 spec).
          run_guarded(conn, :sas_admitted, fun, allowed_hosts)
        else
          conn
          |> put_resp_header("x-ms-version", "2021-12-02")
          |> put_resp_header("x-ms-request-id", generate_request_id())
          |> put_resp_header("x-ms-error-code", "AuthorizationPermissionMismatch")
          |> send_json(403, %{
            "error" => %{
              "code" => "AuthorizationPermissionMismatch",
              "message" =>
                "This request is not authorized to perform this operation using this permission."
            }
          })
          |> halt()
        end

      {:error, :not_sas} ->
        run_guarded(conn, :not_sas, fun, allowed_hosts)

      {:error, reason} when reason in [:bad_signature, :no_key, :malformed] ->
        # KD-15 challenge class: enriched WWW-Authenticate, mode-blind.
        Smalt.Auth.Bearer.send_challenge(
          conn,
          "The SAS signature is invalid or the account key is not configured."
        )

      {:error, :expired} ->
        conn
        |> put_resp_header("x-ms-version", "2021-12-02")
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-error-code", "AuthorizationFailure")
        |> send_json(403, %{
          "error" => %{
            "code" => "AuthorizationFailure",
            "message" => "The SAS token supplied with the request has expired."
          }
        })
        |> halt()
    end
  rescue
    e in [Jason.EncodeError, Protocol.UndefinedError] ->
      Logger.error("blob response encode failure on #{conn.request_path}: #{inspect(e)}")

      send_json(conn, 500, %{
        "error" => %{"code" => "BlobResponseEncodeFailure", "message" => Exception.message(e)}
      })
  end

  # R136: presence-only check let `x-ms-version: ""` (empty value), duplicate
  # headers (valid + junk), and whitespace-only values through to 201-stored.
  # Real Azure answers 400 MissingRequiredHeader. Validate as a SINGLE
  # non-empty, non-blank plausible version value; fail closed with the same
  # typed MissingXMsVersion envelope. SHIM-COURT: this predicate is the
  # mutation surface for the egress-version shim court.
  defp plausible_x_ms_version?(conn) do
    case get_req_header(conn, "x-ms-version") do
      [value] when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp run_guarded(conn, fun, allowed_hosts) do
    if plausible_x_ms_version?(conn) or conn.host in allowed_hosts do
      if not_ready?(conn, [BlobStorage]) or
           not tables_ready?([:smalt_blobs, :smalt_blob_containers, :smalt_blob_policy]) do
        route_not_ready(conn)
      else
        # D1 belt-and-braces: an encode failure in ANY blob response path
        # degrades to a clean JSON 500 envelope — never an empty response.
        reserved_fence_then(conn, fun)
      end
    else
      # AUD6-R1: a request that is neither SAS-admitted nor x-ms-version'ed on
      # a non-allowlisted host previously fell through with conn unsent
      # (Plug.NotSentError). Fail closed with the typed 400 envelope.
      blob_error(conn, 400, %{
        "error" => %{
          "code" => "MissingXMsVersion",
          "message" => "Missing required x-ms-version header, SAS token, or allowlisted host."
        }
      })
      |> halt()
    end
  end

  defp run_guarded(conn, :sas_admitted, fun, _allowed_hosts) do
    if not_ready?(conn, [BlobStorage]) or
         not tables_ready?([:smalt_blobs, :smalt_blob_containers, :smalt_blob_policy]) do
      route_not_ready(conn)
    else
      reserved_fence_then(conn, fun)
    end
  end

  # R124: catch-all tag arm kept adjacent to the :sas_admitted clause so
  # run_guarded/4 stays clause-cohesive (kills the compiler's clause-grouping warning).
  defp run_guarded(conn, _tag, fun, allowed_hosts) do
    run_guarded(conn, fun, allowed_hosts)
  end

  # R99 reserved-namespace fence (D70 worst class). Runs AFTER the SAS /
  # x-ms-version admission guards (the guard 400 envelope keeps precedence
  # for unversioned service-prefix PUTs) and immediately before any splat
  # handler: a splat first segment in @reserved_first_segments is a known
  # OTHER-plane namespace that fell through to the blob catch-alls — cosmos
  # triggers/udfs/sprocs answered 201 with the request body stored as a
  # blob, /secrets/* answered empty blob-list XML, PUT /keys/:name created
  # a blob. Fail closed with a typed refusal in the OWNING plane's JSON
  # error convention (never a blob envelope), naming the unimplemented
  # verb; nothing is stored. Reserved set = the router's own known-plane
  # first segments (moduledoc route families) plus the KV collection roots
  # (secrets, certificates) that appear as splat account names in D70. A
  # literal blob account named exactly one of these is shadowed — accepted
  # cost, impossible to distinguish at this seam.
  defp reserved_fence_then(conn, fun) do
    case conn.path_info do
      # R137 (W5-15 measured): Plug path_info segments are RAW (undecoded);
      # route matching happens on decoded segments, so `PUT /%6beys/vltkey`
      # (encoded "keys") reached the blob splat and stored under the decoded
      # reserved name. Decode+downcase before comparing — mirrors the
      # traversal fence's decode-aware pattern above.
      [first | _rest] ->
        decoded = String.downcase(URI.decode(first))

        if decoded in @reserved_first_segments do
          reserved_namespace_refusal(conn, decoded)
        else
          fun.(conn)
        end

      _ ->
        fun.(conn)
    end
  end

  # KV namespaces answer the KV envelope ({"error":{...}}) 404; every other
  # reserved namespace answers its plane's flat JSON {"code","message"} 400.
  defp reserved_namespace_refusal(conn, ns) when ns in ~w(secrets certificates keys) do
    send_json(conn, 404, %{
      "error" => %{
        "code" => "NotFound",
        "message" =>
          "#{conn.method} #{conn.request_path} is not implemented on this plane " <>
            "(reserved namespace '#{ns}'); nothing was stored."
      }
    })
  end

  defp reserved_namespace_refusal(conn, ns) do
    send_json(conn, 400, %{
      "code" => "NotImplemented",
      "message" =>
        "#{conn.method} #{conn.request_path} is not implemented on this plane " <>
          "(reserved namespace '#{ns}'); nothing was stored."
    })
  end

  # ---------------------------------------------------------------------------
  # Blob Batch (GAP-AUD1-02): multipart/mixed parse → per-sub-request dispatch
  # → multipart/mixed response. Only Delete Blob and Set Blob Tier are
  # dispatched (the two operations real Azure's batch plane accepts); any
  # other sub-request → per-sub-request 400, never a silent skip. Bounded at
  # 256 sub-requests (real Azure's cap).
  # ---------------------------------------------------------------------------

  @batch_max_subrequests 256

  defp blob_batch_arm(conn, account) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, body, conn} ->
        case batch_boundary(conn) do
          {:ok, boundary} ->
            case parse_batch_parts(body, boundary) do
              {:ok, parts} when length(parts) > @batch_max_subrequests ->
                send_json(conn, 400, %{
                  "error" => %{
                    "code" => "SubRequestCountExceedsLimit",
                    "message" =>
                      "The batch request exceeds the limit of #{@batch_max_subrequests} sub-requests."
                  }
                })

              {:ok, []} ->
                send_json(conn, 400, %{
                  "error" => %{
                    "code" => "InvalidInput",
                    "message" => "The batch request contains no sub-requests."
                  }
                })

              {:ok, parts} ->
                send_batch_response(conn, account, parts)
            end

          :error ->
            send_json(conn, 400, %{
              "error" => %{
                "code" => "InvalidInput",
                "message" =>
                  "The batch request requires a multipart/mixed content-type with a boundary."
              }
            })
        end

      {:more, _, _} ->
        send_json(conn, 413, %{
          "error" => %{
            "code" => "RequestBodyTooLarge",
            "message" => "Batch body exceeds the 8 MB cap."
          }
        })
    end
  end

  defp batch_boundary(conn) do
    with [ct] <- get_req_header(conn, "content-type"),
         segments = Enum.map(String.split(ct, ";"), &String.trim/1),
         true <- hd(segments) |> String.downcase() == "multipart/mixed",
         boundary when is_binary(boundary) <- find_boundary(segments) do
      {:ok, String.trim(boundary, "\"")}
    else
      _ -> :error
    end
  end

  defp find_boundary(segments) do
    Enum.find_value(segments, fn segment ->
      case String.split(segment, "boundary=", parts: 2) do
        [_, b] -> String.trim(b)
        [_] -> nil
      end
    end)
  end

  # Splits the multipart body on the boundary and returns each part's
  # sub-request text (part headers stripped; the sub-request begins at the
  # first blank line inside the part). The closing "--boundary--" tail is
  # rejected.
  defp parse_batch_parts(body, boundary) do
    marker = "--" <> boundary

    parts =
      body
      |> String.split(marker)
      |> Enum.reject(fn chunk ->
        # SHIM-COURT-adjacent repair (R33): reject only the exact closing-boundary
        # tail ("--<boundary>--", i.e. a chunk that is just "--" plus whitespace),
        # not any chunk whose body merely starts with "--".
        trimmed = String.trim(chunk)
        trimmed in ["", "--"]
      end)
      |> Enum.map(fn chunk ->
        chunk
        |> String.trim_leading("\r\n")
        |> String.trim_trailing("\r\n")
        |> strip_part_headers()
      end)

    {:ok, parts}
  end

  # R67: hand-rolled curl batches may use LF-only line endings. Normalize lone
  # \n to \r\n so the header-block split below does not swallow the part head
  # into the sub-request line (which yielded a typed 400 per sub-request).
  defp strip_part_headers(chunk) do
    case :binary.split(normalize_crlf(chunk), "\r\n\r\n") do
      [_, sub_request] -> String.trim_leading(sub_request, "\r\n")
      [_] -> chunk
    end
  end

  defp send_batch_response(conn, _account, parts) do
    boundary = "batchresponse_" <> generate_request_id()

    chunks =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {sub_request, idx} ->
        {status, headers, body} = dispatch_batch_subrequest(sub_request, idx)
        render_batch_part(idx, status, headers, body, boundary)
      end)

    response_body = IO.iodata_to_binary([chunks, "\r\n--", boundary, "--\r\n"])

    conn
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
    |> send_resp(202, response_body)
  end

  defp render_batch_part(idx, status, headers, body, boundary) do
    header_lines = Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)

    body_block =
      if body in [nil, ""] do
        ""
      else
        body
      end

    IO.iodata_to_binary([
      "\r\n--",
      boundary,
      "\r\nContent-Type: application/http\r\nContent-ID: ",
      Integer.to_string(idx),
      "\r\n\r\nHTTP/1.1 ",
      Integer.to_string(status),
      " ",
      plug_status_reason(status),
      "\r\n",
      header_lines,
      "\r\n\r\n",
      body_block,
      "\r\n"
    ])
  end

  defp plug_status_reason(status) do
    Plug.Conn.Status.reason_phrase(status)
  end

  # Dispatches one sub-request. Supported: Delete Blob, Set Blob Tier.
  # Returns {status, headers_list, body_string_or_empty}.
  defp dispatch_batch_subrequest(sub_request, _idx) do
    case parse_sub_request(sub_request) do
      {method, target, headers, _body} ->
        uri = URI.parse(target)
        query = URI.decode_query(uri.query || "")
        segments = Enum.reject(String.split(uri.path || "", "/"), &(&1 == ""))

        batch_dispatch_op(method, segments, query, headers)

      :error ->
        {400, [{"x-ms-error-code", "InvalidInput"}],
         batch_error_body("InvalidInput", "Malformed sub-request.")}
    end
  end

  defp batch_dispatch_op("DELETE", [account, container | blob_segments], _query, headers) do
    blob_name = Enum.join(blob_segments, "/")

    case BlobStorage.delete_blob(account, container, blob_name, headers) do
      {:ok, status, headers, _record} ->
        {status, Map.to_list(headers), ""}

      {:error, status, code, msg} ->
        {status, [{"x-ms-error-code", code}], batch_error_body(code, msg)}
    end
  end

  defp batch_dispatch_op(
         "PUT",
         [account, container | blob_segments],
         %{"comp" => "tier"},
         headers
       ) do
    blob_name = Enum.join(blob_segments, "/")

    case BlobStorage.set_blob_tier(account, container, blob_name, headers["x-ms-access-tier"]) do
      {:ok, status, headers, _} ->
        {status, Map.to_list(headers), ""}

      {:error, status, code, msg} ->
        {status, [{"x-ms-error-code", code}], batch_error_body(code, msg)}
    end
  end

  defp batch_dispatch_op(_method, _segments, _query, _headers) do
    {400, [{"x-ms-error-code", "InvalidOperation"}],
     batch_error_body("InvalidOperation", "Unsupported batch sub-request operation.")}
  end

  defp batch_error_body(code, msg) do
    Jason.encode!(%{"error" => %{"code" => code, "message" => msg}})
  end

  # Parses an HTTP sub-request: "METHOD /path?query HTTP/1.1" + headers
  # [+ body]. Returns {method, target, headers_map, body} or :error.
  defp parse_sub_request(sub) do
    case :binary.split(sub, "\r\n\r\n") do
      [head, body] -> parse_sub_head(head, body)
      [_] -> parse_sub_head(sub, "")
    end
  end

  # R67: same LF normalization for the sub-request head itself (request line +
  # header lines), so an LF-only sub-request inside an otherwise-CRLF part parses.
  defp parse_sub_head(head, body) do
    [req_line | header_lines] = String.split(normalize_crlf(head), "\r\n")
    segments = String.split(String.trim(req_line), " ")

    with [method, target, _version] <- segments do
      headers =
        header_lines
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          case :binary.split(line, ":") do
            [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
            [k] -> {String.downcase(String.trim(k)), ""}
          end
        end)
        |> Map.new()

      {method, target, headers, body}
    else
      _ -> :error
    end
  end

  # R67: replace "\r\n" with "\n" first, then "\n" with "\r\n" — normalizes
  # lone LF to CRLF without doubling existing CRLF.
  defp normalize_crlf(bin) do
    bin
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end

  # F5 (compliance-corpus lens-4 work order): real Azure emits
  # x-ms-request-id + x-ms-version on ERROR responses too. Blob-plane-scoped
  # renderer — shared send_json is untouched (ARM/LA/Cosmos/KV envelope pins
  # must not see blob headers). v4 GUID from generate_request_id/0.
  # Quoted opaque container ETag for the Put Container 201 render — delegates
  # to the single derivation in BlobService.container_etag/1 (R62 repair 1),
  # stable per (account, container, created_at).
  defp container_put_etag(record) do
    BlobService.container_etag(record)
  end

  # Lane 06 (v26.10.14) defect 3, part 1: on the blob comp=list routes the
  # real Azure Blob service answers typed errors with an XML
  # <?xml?><Error><Code/><Message/></Error> envelope (Content-Type
  # application/xml), not JSON. Scoped to the comp=list arms only — every
  # other blob_error/3 consumer (ledger, cosmos, KV, attestation, sentinel)
  # keeps byte-identical JSON output.
  defp blob_error_xml(conn, status, code, message) do
    xml =
      ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>#{BlobService.xml_escape(code)}</Code><Message>#{BlobService.xml_escape(message)}</Message></Error>)

    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_resp_header("x-ms-error-code", code)
    |> put_resp_content_type("application/xml")
    |> send_resp(status, xml)
  end

  # ---------------------------------------------------------------------------
  # GAP-AUD1-01 (v26.10.14, lane W-5): blob comp whitelist.
  #
  # The generic Put/Get Blob fallback arms previously absorbed every `comp`
  # value they did not name (appendblock, snapshot, page, pagelist, tags,
  # query, tier, expiry, seal, lease, copy) and silently overwrote / served
  # the blob body — the AUD-1 headline corruption class. Whitelist = exactly
  # the comps with implemented handlers on each arm. Container-level comps
  # (list, acl, legalhold, immutabilityPolicy) are routed on the container
  # routes and never reach these arms. Unimplemented features stay KD rows;
  # the class is dead because an unlisted comp can no longer touch the body.
  # ---------------------------------------------------------------------------

  # R124: the blob and container `?/2` predicates were byte-identical —
  # collapsed into one helper. The two error envelopes stay separate
  # functions (their messages genuinely differ; see each below).
  defp unhandled_comp?(conn, allowed) do
    case conn.query_params["comp"] do
      v when is_binary(v) and v != "" -> v not in allowed
      # A14 (D14/KD-60): Plug decodes duplicate query keys into a LIST, so
      # ?comp=metadata&comp=lease yields %{"comp" => ["metadata", "lease"]} —
      # the is_binary/1 clause above admitted it, skipping every whitelist and
      # falling into the true -> catch-all (201-lie class reopened on both
      # blob and container arms). Default-deny: any list-form comp refuses.
      v when is_list(v) -> true
      _ -> false
    end
  end

  # A14: error-envelope rendering for the list-form comp — "a, b", not the
  # Elixir inspect of a list.
  defp comp_str(v) when is_list(v), do: Enum.join(v, ", ")
  defp comp_str(v), do: v

  # R124 message convention (both comp-error envelopes): the wire-visible
  # prefix `The comp value '<v>' is not supported` is byte-identical and
  # test-pinned (blob_hardening_test.exs). The GAP clause
  # `(GAP(blob-comp-lease-absent)): ...` is appended ONLY where a registered
  # GAP row names the comp family — container lease/ACL — never on the blob
  # arm, whose unhandled comps (appendblock, snapshot, page, ...) span more
  # than the lease GAP and would overclaim.
  defp unhandled_blob_comp_error(conn, v) do
    blob_error(conn, 400, %{
      "error" => %{
        "code" => "InvalidQueryParameterValue",
        "message" => "The comp value '#{comp_str(v)}' is not supported."
      }
    })
  end

  # R98 container comp whitelist (mirror of the blob-arm whitelist above).
  # restype=container carries no comp and comp=nil is admitted; any other
  # comp value with no implemented container handler answers the same typed
  # InvalidQueryParameterValue envelope as the blob arms, naming the registered
  # GAP so the wire no longer lies via fallthrough (PUT 201 / GET 200).
  defp unhandled_container_comp_error(conn, v) do
    blob_error(conn, 400, %{
      "error" => %{
        "code" => "InvalidQueryParameterValue",
        "message" =>
          "The comp value '#{comp_str(v)}' is not supported (GAP(blob-comp-lease-absent)): " <>
            "container leases and ACLs are not implemented."
      }
    })
  end

  # x-ms-meta-* request headers -> %{"name" => "value"} map (BlobService
  # container metadata). Response direction: meta dict -> x-ms-meta-* headers.
  # Wire body (Azure shape) -> BlobStorage.set_immutability_policy/5 policy map.
  #
  # Body seam: Plug.Parsers may already have consumed and decoded the JSON
  # body (body_params is a map) — re-reading the stream would return "" and
  # lose the policy. Read body_params first; read_body is only the fallback
  # for unparsed content-types. A non-empty body that fails to decode is a
  # 400 InvalidXmlOrJson, never a nil-expires 500 downstream.
  defp immutability_policy_from_wire(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case Plug.Conn.read_body(conn) do
          {:ok, raw, conn} -> decode_policy_body(raw, conn)
          {:error, _reason} -> {:error, conn}
        end

      params when is_map(params) ->
        {:ok, policy_from_params(params), conn}

      _other ->
        {:error, conn}
    end
  end

  # KD-108 wire seam (ACL PUT): the raw SignedIdentifiers body may already
  # have been consumed by Plug.Parsers (a urlencoded/json Content-Type — curl's
  # default for --data-binary is x-www-form-urlencoded — matches :urlencoded
  # and eats the XML). Read the raw cache first (Smalt.Auth.BodyCache stashes
  # the complete raw body in :smalt_raw_body whenever a parser ran), fall back
  # to the stream for parser-exempt requests (raw_blob_put? style paths).
  # Without this, read_body/1 returns "" and the ACL arm silently CLEARS the
  # signed identifiers (204 with parse_signed_identifiers("") == {:ok, []}).
  defp acl_body(conn) do
    case conn.private[:smalt_raw_body] do
      raw when is_binary(raw) -> {:ok, raw, conn}
      _ ->
        case Plug.Conn.read_body(conn) do
          {:ok, raw, conn} -> {:ok, raw, conn}
          {:error, reason} -> {:error, 400, "InvalidRequestBody", inspect(reason)}
        end
    end
  end

  defp decode_policy_body("", conn), do: {:ok, %{}, conn}

  defp decode_policy_body(raw, conn) do
    case Jason.decode(raw) do
      {:ok, %{} = body} -> {:ok, policy_from_params(body), conn}
      _ -> {:error, conn}
    end
  end

  defp policy_from_params(body) do
    %{
      "locked" => Map.get(body, "locked", false) == true,
      "period_days" => period_days(Map.get(body, "immutabilityPeriodSinceCreationInDays", 0)),
      "until" => Map.get(body, "expiresOn")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp period_days(days) when is_integer(days), do: days

  defp period_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, ""} -> n
      _ -> days
    end
  end

  defp period_days(other), do: other

  defp meta_headers(%Plug.Conn{} = conn) do
    Enum.reduce(conn.req_headers, %{}, fn {name, value}, acc ->
      case name do
        "x-ms-meta-" <> meta_name -> Map.put(acc, meta_name, value)
        _ -> acc
      end
    end)
  end

  defp meta_headers(meta) when is_map(meta) do
    Map.new(meta, fn {name, value} -> {"x-ms-meta-#{name}", to_string(value)} end)
  end

  # KD-01 echo: stored x-ms-meta-* ride GET/HEAD blob responses (Azure Get
  # Blob metadata). Scoped to the x-ms-meta-* subset — the stored header map
  # carries the full PUT request headers (auth, x-ms-version) and only user
  # metadata is wire-safe to emit.
  defp stored_meta_wire(blob) do
    blob
    |> Map.get("headers", %{}) ||
      %{}
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "x-ms-meta-") end)
  end

  # T-18 (v26.10.28): the content type a blob GET/HEAD serves is the one Set
  # Blob HTTP Headers stored (x-ms-blob-content-type on the record's header
  # map) — falling back to the service default when never set.
  defp stored_content_type(blob) do
    case get_in(blob, ["headers", "x-ms-blob-content-type"]) do
      ct when is_binary(ct) and ct != "" -> ct
      _ -> "application/octet-stream"
    end
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn
      # Engine header maps may carry nil values (measured: BlobService
      # get_container_properties emits "last-modified" => nil on a fresh
      # container — HEAD container crashed with FunctionClauseError inside
      # put_resp_header). nil means "header absent" at this seam; skip it.
      {_name, nil}, conn -> conn
      {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value)
    end)
  end

  # BlobService header-only responses (container metadata PUT / properties).
  defp send_headers(conn, status, headers) do
    put_resp_headers(conn, headers)
    |> send_resp(status, "")
  end

  defp put_message(body, msg), do: put_in(body, ["error", "message"], msg)


  # T07 split: front typed-404 fallback catch-all. Matches everything the splat
  # routes did not claim and passes through UNSENT (un-halted, state :unset) so
  # the front's post-dispatch `:storage_dispatch` plug renders the typed 404
  # envelope exactly where the pre-split `match _` inside the front used to.
  match _ do
    conn
  end
end
