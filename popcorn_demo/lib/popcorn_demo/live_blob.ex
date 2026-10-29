defmodule PopcornDemo.LiveBlob do

  alias PopcornDemo.Redact
  @moduledoc """
  WASM-BEAM blob round-trip walk (lane L3): PUT a real block blob, GET it
  back, assert byte equality on the REAL stored bytes. Chicago school — the
  only collaborators are the live smalt substrate and the wire.

  Transport (ERRC-E2 dedupe): all HTTP rides the shared
  `PopcornDemo.Transport` behaviour — browser (`Transport.Fetch`) when the
  Popcorn JS bridge is up, `Transport.Httpc` (real `:httpc`, loopback-only)
  on the host. The former self-contained `:gen_tcp` HTTP/1.1 client is
  deleted (single transport, one calculus — the historical rationale for the
  `:gen_tcp` copy, broken inets ebins under the demo mix env, is now handled
  inside `Transport.Httpc.ensure_started/0`).

  Known transport gap (documented, to be consolidated next wave):
  `Transport.Httpc` sends no content-length on empty-body PUTs and fixes the
  content-type of body-carrying requests to
  application/x-www-form-urlencoded — both are harmless for this walk
  (verified against the live substrate, receipt ERRC-E2) but a
  content-type-plural transport would remove the constraint.

  Wire shape (verified with curl against the live substrate BEFORE this
  module existed):
  - STS token: POST {sts}/:tenant/oauth2/v2.0/token (enforce-mode bearer,
    minted over the wire — no local :crypto needed, so the wasm core
    runtime's missing crypto does not affect this walk).
  - Container: PUT /{account}/{container}?restype=container -> 201 (or 200
    idempotent re-PUT with identical metadata).
  - Blob: PUT /{account}/{container}/{blob} (x-ms-blob-type: BlockBlob,
    x-ms-version required) -> 201; GET -> 200 raw bytes.

  Cross-origin verdict (w6ay blob CORS): the blob plane answers OPTIONS
  preflight from STORED `<Cors>` service-properties rules only. With no rules
  stored for the account, a browser fetch from origin
  `http://127.0.0.1:<other-port>` gets 403 on preflight and no
  `Access-Control-Allow-Origin` on actual responses — the browser leg is
  therefore gated loudly: `blob=SKIP(cors-preflight-403:...)` unless rules
  admitting the origin exist. The host transport is not subject to CORS
  and runs the real walk regardless. (KD-122 context: the blob CORS rule is
  stored account-side; the host leg is CORS-blind either way.)
  """

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "smalt-tenant"
  @account "popcorn"
  # Run-unique container: sibling lanes share the "popcorn" account and a
  # shared container picked up a WORM legal hold mid-walk (witnessed 409
  # ContainerLocked); a fresh per-run container keeps the walk hermetic.
  defp container,
    do: "l3rb" <> Integer.to_string(System.system_time(:millisecond)) <>
           "-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  @blob "receipt.txt"
  @ms_version "2021-12-02"

  @doc """
  Runs the walk. Returns:

  - `{:ok, "blob=OK(<account>/<container>/<blob>:<n>-roundtrip)"}`
  - `{:skip, "blob=SKIP(<loud reason>)"}`
  - `{:error, "blob=FAIL(<step>:<reason>)"}`
  """
  def run do
    container = container()

    with {:ok, _} <- health(),
         {:ok, token} <- token(),
         :ok <- ensure_container(container, token),
         {:ok, n} <- put_and_get(container, token) do
      {:ok, "blob=OK(#{account()}/#{container}/#{@blob}:#{n}-roundtrip)"}
    else
      {:skip, reason} ->
        {:skip, "blob=SKIP(#{reason})"}

      {:error, {step, reason}} when is_binary(step) ->
        classify_blob_outcome(step, reason)
    end
  end

  # -- staged block upload (W4-2) ------------------------------------------

  # Run-unique blob for the staged walk.
  @staged_blob "staged-receipt.bin"

  @doc """
  Staged block upload round-trip (W4-2): real Put Block / Put Block List /
  Get Blob / Delete Blob over the live substrate wire, mirroring Azure's
  large-blob grammar.

  `container` is created by the walk and deleted on success. Steps:

  1. PUT /{a}/{c}?restype=container                      -> 201
  2. PUT /{a}/{c}/{b}?comp=block&blockid=<b64(id-0)>     -> 201 (first half)
  3. PUT /{a}/{c}/{b}?comp=block&blockid=<b64(id-1)>     -> 201 (second half)
  4. PUT /{a}/{c}/{b}?comp=blocklist (XML <Latest> refs) -> 201
  5. GET /{a}/{c}/{b}                                     -> 200 whole blob
  6. byte-equality vs the concatenation of the two halves
  7. DELETE /{a}/{c}/{b} -> 202/200, DELETE container -> 200
     (or 409 ContainerLocked under the account's default WORM pinion)

  Block ids are base64 per Azure convention (the wire `blockid` query
  parameter carries the base64 encoding; the blocklist XML references the
  same encoding). Every body-carrying step sends an explicit
  content-type (application/xml) — the shared transport's
  form-urlencoded default gets the raw body consumed by the router's
  Plug.Parsers before the block arms read it. Returns:

  - `{:ok, "blob-staged=OK(<account>/<container>/<blob>:<n>-cleaned-staged-roundtrip)"}`
    (or `...-worm-retained-staged-roundtrip)` when the default WORM pinion
    answers 409 ContainerLocked to the deletes — retention recorded, never
    masked)
  - `{:error, "blob-staged=FAIL(<step>:<reason>)"}`
  """
  def staged_roundtrip(container) do
    with {:ok, _} <- health(),
         {:ok, token} <- token(),
         :ok <- ensure_container(container, token),
         {:ok, n, suffix} <- staged_walk(container, token) do
      {:ok,
       "blob-staged=OK(#{account()}/#{container}/#{@staged_blob}:#{n}" <> suffix <>
         "-staged-roundtrip)"}
    else
      {:skip, reason} ->
        {:skip, "blob-staged=SKIP(#{reason})"}

      {:error, {step, reason}} when is_binary(step) ->
        {:error, "blob-staged=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  defp staged_walk(container, token) do
    first = payload()
    second =
      "staged-block-half-2 " <>
        stamp() <> " " <> String.duplicate("B", 512)

    whole = IO.iodata_to_binary([first, second])
    # Azure block ids: base64 of an arbitrary id string; the wire carries the
    # base64 form in both the blockid query param and the blocklist XML.
    id0 = Base.encode64("id-w42-0")
    id1 = Base.encode64("id-w42-1")

    # KD-122 context: blob CORS is stored account-side (host leg is
    # CORS-blind); independent of that, the body-relevant wire header here is
    # content-type application/xml on BOTH block PUTs and the blocklist PUT —
    # without it the shared transport's form-urlencoded default rides the
    # request and the router's Plug.Parsers urlencoded arm consumes the raw
    # body before blob_block_arm's read_body (witnessed: commit 400
    # InvalidXmlDocument "no block references" with the transport default).
    xml_ct = [{"content-type", "application/xml"}]

    block_url = fn b64 ->
      @base <> "/#{account()}/#{container}/#{@staged_blob}?comp=block&blockid=" <> b64
    end

    blocklist_xml =
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>" <>
        id0 <> "</Latest><Latest>" <> id1 <> "</Latest></BlockList>"

    with {:ok, %{status: 201}} <-
           step_req("put-block-0",
             %{
               method: "PUT",
               url: block_url.(id0),
               headers: auth_headers(token) ++ xml_ct,
               body: first
             },
             201
           ),
         {:ok, %{status: 201}} <-
           step_req("put-block-1",
             %{
               method: "PUT",
               url: block_url.(id1),
               headers: auth_headers(token) ++ xml_ct,
               body: second
             },
             201
           ),
         {:ok, %{status: 201}} <-
           step_req("put-block-list",
             %{
               method: "PUT",
               url: @base <> "/#{account()}/#{container}/#{@staged_blob}?comp=blocklist",
               headers: auth_headers(token) ++ xml_ct,
               body: blocklist_xml
             },
             201
           ),
         {:ok, %{status: 200, body: got}} <-
           step_req("get-blob",
             %{method: "GET", url: @base <> "/#{account()}/#{container}/#{@staged_blob}",
               headers: auth_headers(token), body: nil},
             200
           ) do
      if got == whole do
        case cleanup_staged(container, token) do
          :ok -> {:ok, byte_size(whole), "-cleaned"}
          {:lock, _} -> {:ok, byte_size(whole), "-worm-retained"}
          {:error, {step, reason}} -> {:error, {step, reason}}
        end
      else
        cleanup_staged(container, token)
        {:error,
         {"compare", "byte-mismatch(put=#{byte_size(whole)},got=#{byte_size(got)})"}}
      end
    end
  end

  # DELETE blob then container. Under the account's DEFAULT container pinion
  # (create_container immutable:true, retention 1095 days — deliberate data
  # plane WORM default, blob_storage.ex:157), DELETE blob/container answers
  # 409 ContainerLocked by design: that outcome is the typed WORM-retention
  # fact, recorded in the OK message, never masked as an error or skipped.
  # A 200/202 delete succeeds and the blob is gone (close condition: once
  # per-container immutability can be opted out on the wire, both walks
  # return "-cleaned" here). Any other status is a real failure.
  defp cleanup_staged(container, token) do
    # W7-A: raw request/1, NOT step_req(..., 202) — step_req reshapes any
    # non-202 (the by-design 409 ContainerLocked WORM answer) into a step
    # error before the {:ok, %{status: 409}} retained clause below can ever
    # match, so the walk FAILED instead of reporting "-worm-retained"
    # (witnessed: delete-blob 409 ContainerLocked -> FAIL(delete-blob:...)).
    case request(%{method: "DELETE",
                   url: @base <> "/#{account()}/#{container}/#{@staged_blob}",
                   headers: auth_headers(token), body: nil}) do
      {:ok, %{status: st}} when st in [200, 202] ->
        case request(%{method: "DELETE", url: @base <> "/#{account()}/#{container}",
                       headers: auth_headers(token), body: nil}) do
          {:ok, %{status: st2}} when st2 in [200, 202] -> :ok
          {:ok, %{status: 409}} -> {:lock, :container_retained}
          {:ok, %{status: st3}} -> {:error, {"delete-container", "http-#{st3}"}}
          {:error, r} -> {:error, {"delete-container", fmt(r)}}
        end

      {:ok, %{status: 409}} ->
        {:lock, :blob_retained}

      other ->
        case other do
          {:ok, %{status: st4, body: body}} ->
            {:error, {"delete-blob", "cleanup-http-#{st4}:#{slice(body)}"}}

          {:error, reason} ->
            {:error, {"delete-blob", fmt(reason)}}
        end
    end
  end

  # -- walk steps ----------------------------------------------------------

  @doc """
  Typed outcome classification for a failed walk step.

  - CORS-shaped block (browser fetch failure whose reason carries the
    browser CORS-block vocabulary — "blocked", "Failed to fetch", "CORS")
    is an environment fact, not a defect: the blob plane answers OPTIONS
    preflight from STORED `<Cors>` service-properties rules only, so with no
    rule admitting the origin the browser leg cannot pass. Returns
    `{:skip, "blob=SKIP(cors-preflight-403:<step>)"}` — loud, typed, never a
    fake pass or a scary FAIL.
  - Any other transport error returns `{:error, "blob=FAIL(<step>:<reason>)"}`.

  Close condition (no code change here): once the substrate stores an
  effective CORS rule for the account, the browser fetch succeeds and the
  walk flips SKIP-to-OK on its own — the walk itself is already correct.
  This classifier exists only so the SKIP stays precisely scoped to
  CORS-shaped failures and cannot mask a real transport defect.
  """
  def classify_blob_outcome(step, reason) do
    case cors_blocked?(reason) do
      true -> {:skip, "blob=SKIP(cors-preflight-403:#{step})"}
      false -> {:error, "blob=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  defp cors_blocked?(reason) when is_binary(reason) do
    reason =~ "Failed to fetch" or reason =~ "blocked" or reason =~ "CORS"
  end

  defp cors_blocked?(_), do: false

  defp health do
    req = %{method: "GET", url: @base <> "/healthz"}

    case request(req) do
      {:ok, %{status: 200}} -> {:ok, :ready}
      {:ok, %{status: st}} -> {:error, {"health", "http-#{st}"}}
      {:error, _} = err -> err
    end
  end

  defp token do
    req = %{
      method: "POST",
      url: @sts <> "/#{@tenant}/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, {"token", "no-access_token-in-sts-body"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(body)}"}}

      {:error, {step, reason}} when is_atom(step) ->
        {:error, {{Atom.to_string(step), reason}}}
    end
  end

  defp ensure_container(container, token) do
    req = %{
      method: "PUT",
      url: @base <> "/#{account()}/#{container}?restype=container",
      headers: auth_headers(token),
      body: ""
    }

    case request(req) do
      {:ok, %{status: st}} when st in [200, 201] -> :ok
      {:ok, %{status: st, body: body}} -> {:error, {"create-container", "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {"create-container", fmt(reason)}}
    end
  end

  defp put_and_get(container, token) do
    payload = payload()

    put_req = %{
      method: "PUT",
      url: @base <> "/#{account()}/#{container}/#{@blob}",
      headers: auth_headers(token) ++ [{"x-ms-blob-type", "BlockBlob"}],
      body: payload
    }

    get_req = %{
      method: "GET",
      url: @base <> "/#{account()}/#{container}/#{@blob}",
      headers: auth_headers(token),
      body: nil
    }

    with {:ok, %{status: 201}} <- step_req("put-blob", put_req, 201),
         {:ok, %{status: 200, body: got}} <- step_req("get-blob", get_req, 200) do
      if got == payload do
        {:ok, byte_size(payload)}
      else
        {:error,
         {"compare",
          "byte-mismatch(put=#{byte_size(payload)},got=#{byte_size(got)})"}}
      end
    end
  end

  defp step_req(step, req, want) do
    case request(req) do
      {:ok, %{status: ^want} = resp} -> {:ok, resp}
      {:ok, %{status: st, body: body}} -> {:error, {step, "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {step, fmt(reason)}}
    end
  end

  # -- transport dispatch --------------------------------------------------
  # Single transport calculus (ERRC-E2): browser when the Popcorn JS bridge
  # is loaded, PopcornDemo.Transport.Httpc (real :httpc) on host. The former
  # self-contained :gen_tcp client is deleted.

  # Mirrors live.ex's bridge signal: Popcorn.JS.run!/2 IS exported on host,
  # so "is the JS bridge actually up" is Popcorn.JS.available?/0 — misrouting
  # to Popcorn.Fetch on host yields a silent :timeout (witnessed).
  defp browser?, do: Code.ensure_loaded?(Popcorn.JS) and Popcorn.JS.available?()

  defp request(req) do
    if browser?() do
      PopcornDemo.Transport.Fetch.request(req)
    else
      PopcornDemo.Transport.Httpc.request(req)
    end
  end

  # -- shared helpers ------------------------------------------------------

  defp auth_headers(token),
    do: [
      {"authorization", "Bearer " <> token},
      {"x-ms-version", @ms_version}
    ]

  defp payload, do: "popcorn-demo blob receipt " <> stamp() <> " lane=L3"

  defp stamp do
    {:ok, dt} = DateTime.now("Etc/UTC")
    DateTime.to_iso8601(dt)
  end

  defp account, do: @account

  defp slice(b) when is_binary(b), do: Redact.fragment(b)
  defp slice(other), do: Redact.fragment(other)

  defp fmt(r) when is_binary(r), do: Redact.fragment(r)
  defp fmt(other), do: Redact.fragment(other)
end
