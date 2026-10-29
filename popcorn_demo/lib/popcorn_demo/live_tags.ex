defmodule PopcornDemo.LiveTags do
  @moduledoc """
  W4-5 — resource-tags leg (Fortune-5 governance 101) over the REAL smalt
  substrate (ARM control plane 9443). No mocks.

  One `run/0`:

    1. mint an STS bearer at `POST /{tenant}/oauth2/v2.0/token`
    2. ensure RG `popcorn-tags-rg` via ARM PUT
    3. PUT containerApp `popcorn-tags-ca` via the generic provider resource
       PUT with `tags` IN THE RESOURCE BODY
       (%{"env" => "popcorn", "owner" => "testbed"}) — router.ex
       build_resource_record/5 persists tags via normalize_tags/1
       (null-when-empty law)
    4. GET the app back and assert the tags round-trip byte-shape
       (exact map, key order irrelevant, values exact)
    5. PUT again with a CHANGED tag set (full replace via the generic PUT:
       %{"env" => "prod", "team" => "popcorn"}) — ARM PUT semantics are a
       full replace of the tags member — then GET and assert the update
       took and the removed tag is gone.

  Wire seam: lib/smalt/arm_gateway/router.ex handle_resource_put ->
  build_resource_record ("tags" => normalize_tags(payload["tags"])) ->
  Store :smalt_resources; GET renders the stored record.

  Receipts (run/0 return), house style:
    {:ok,    "tags=OK(<n>-tags-roundtrip)"}            n = tag count
    {:skip,  "tags=SKIP(transport:<reason>)"}          -- substrate down
    {:error, "tags=FAIL(<step>:<reason>)"}             -- any other failure

  Transport (ERRC-E2 dedupe, CLOSED): all HTTP rides
  `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`) — the former private `:httpc` client +
  `repair_code_path` copy is deleted; single transport, one calculus.
  `Transport.Httpc` returns RAW binary bodies and does not JSON-decode, so
  `decode_body/1` stays at THIS module's edge (walk steps pattern-match on
  decoded JSON). Transport's resp contract carries `{status, body}` only —
  response headers are not surfaced, so the tokenless test seam
  (`fetch_tokenless/0`) witnesses the KD-15 refusal at status level (401).

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` + test seams only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2023-05-01"

  @sub_id "popcorn-tags-rg-sub"
  @rg "popcorn-tags-rg"
  @ca_type "Microsoft.App/containerApps"

  @rg_base "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  @ca_base "#{@rg_base}/providers/Microsoft.App/containerApps"

  @tags_v1 %{"env" => "popcorn", "owner" => "testbed"}
  @tags_v2 %{"env" => "prod", "team" => "popcorn"}

  # RUN-UNIQUE app name (live_lifecycle/live_kv pattern): a fixed
  # "popcorn-tags-ca" self-collides under parallel full-suite runs — two
  # concurrent walkers PUT/GET the same record and the tag-set asserts race.
  # The name is process-local so the test seams (app_path/0,
  # fetch_tagged_app/0) in the SAME ExUnit test process resolve to the same
  # app; a different process mints its own.
  defp unique_app do
    "popcorn-tags-ca-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp app do
    Process.get({__MODULE__, :resname}) || unique_app()
  end

  @doc "Full walk: tags round-trip + update through the generic resource PUT."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    Process.put({__MODULE__, :resname}, unique_app())

    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- put_app_tags(@tags_v1),
         {:ok, rec} <- get_app(),
         :ok <- roundtrip_check(rec, @tags_v1),
         :ok <- put_app_tags(@tags_v2),
         {:ok, rec2} <- get_app(),
         :ok <- update_check(rec2, @tags_v2) do
      {:ok, "tags=OK(#{map_size(@tags_v2)}-tags-roundtrip)"}
    end
  end

  # -- Steps -----------------------------------------------------------------

  defp slice(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp slice(r), do: r |> inspect() |> String.slice(0, 120)

  defp mint do
    body =
      "grant_type=client_credentials&client_id=x&client_secret=y" <>
        "&scope=#{@scope}"

    case req(:post, "#{@base}/#{@tenant}/oauth2/v2.0/token",
            body: body,
            headers: [{"content-type", "application/x-www-form-urlencoded"}]
          ) do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        Process.put({__MODULE__, :token}, tok)
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "tags=FAIL(mint:STS-status-#{s}-body=#{slice(b)})"}

      {:error, reason} ->
        {:skip, "tags=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, @rg_base, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "tags=FAIL(ensure_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "tags=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Tags ride the GENERIC PUT in the resource body (ARM parity: PUT is a full
  # replace of the tags member — omitted/empty tags clear them).
  defp put_app_tags(tags) do
    body = %{
      "location" => "eastus",
      "tags" => tags,
      "properties" => %{
        "environmentId" => "",
        "template" => %{"containers" => []},
        "configuration" => %{}
      }
    }

    case arm_req(:put, app_path(), body) do
      {:ok, %{status: s}} when s in [200, 201, 202] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "tags=FAIL(put_app_tags:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "tags=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp get_app do
    case arm_req(:get, app_path()) do
      {:ok, %{status: 200, body: %{"name" => _} = record}} ->
        {:ok, record}

      {:ok, %{status: s, body: b}} ->
        {:error, "tags=FAIL(get_app:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "tags=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Byte-shape: the wire tags map must EQUAL the PUT map exactly.
  defp roundtrip_check(record, expected) do
    if record["tags"] == expected do
      :ok
    else
      {:error,
       "tags=FAIL(roundtrip:got-#{slice(record["tags"])}-want-#{slice(expected)})"}
    end
  end

  defp update_check(record, expected) do
    cond do
      record["tags"] != expected ->
        {:error,
         "tags=FAIL(update:got-#{slice(record["tags"])}-want-#{slice(expected)})"}

      # Full-replace law: the removed v1 tag must be GONE, not merged.
      Map.has_key?(record["tags"] || %{}, "owner") ->
        {:error, "tags=FAIL(update:removed-tag-owner-still-present)"}

      true ->
        :ok
    end
  end

  # -- Test seams (public) ----------------------------------------------------

  @doc "ARM path of the tagged containerApp (run-unique app name)."
  def app_path, do: "#{@ca_base}/#{app()}"

  @doc "RG path."
  def rg_path, do: @rg_base

  @doc "Initial tag set (round-trip witness)."
  def tags_v1, do: @tags_v1

  @doc "Updated tag set (update witness)."
  def tags_v2, do: @tags_v2

  @doc "Admitted ARM type under test."
  def resource_type, do: @ca_type

  @doc """
  Real HTTP GET of the tagged app over the live substrate (test seam).
  Requires run/0 (or the test's own mint) to have set the bearer.
  """
  def fetch_tagged_app do
    with :ok <- mint(),
         :ok <- ensure_rg(),
         {:ok, %{status: 200, body: %{"name" => _}} = res} <- get_app() do
      {:ok, res.body}
    end
  end

  @doc """
  Tokenless negative (test seam): real GET with NO bearer. Enforce mode must
  answer 401 (KD-15 challenge handshake shape; Transport surfaces
  `{status, body}` only, so the refusal is witnessed at status level).
  """
  def fetch_tokenless do
    Process.delete({__MODULE__, :token})
    req(:get, "#{@base}#{app_path()}?#{@api}")
  end

  defp arm_req(method, path, body_map \\ nil) do
    url = "#{@base}#{path}?#{@api}"

    if body_map do
      req(method, url,
        body: Jason.encode!(body_map),
        headers: [{"content-type", "application/json"}]
      )
    else
      req(method, url)
    end
  end

  # -- Transport (single calculus, mirrors LiveMatrix/LiveRules) --------------
  # Popcorn.Fetch when the JS bridge is up (browser WASM leg), else host
  # PopcornDemo.Transport.Httpc (real :httpc) — same request/response map
  # shape either way. The former private :httpc client + repair_code_path
  # copy is deleted.

  # Browser transport when the Popcorn JS bridge is up (mirrors live_blob's
  # signal: Popcorn.JS.available?/0); host requests ride Transport.Httpc.
  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(method, url, opts \\ []) do
    # Browsers reject GET/HEAD with a body (even ""); Popcorn.Fetch forwards
    # it verbatim — omit body on GET (witnessed in-browser, 2026-10-20).
    body =
      if method == :get and not Keyword.has_key?(opts, :body),
        do: nil,
        else: Keyword.get(opts, :body, "")

    request = %{
      method: String.upcase(to_string(method)),
      url: url,
      headers: headers_for(Keyword.get(opts, :headers, [])),
      body: body
    }

    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  # PopcornDemo.Transport returns raw binary bodies; the walk steps
  # pattern-match on decoded JSON. Decode best-effort at THIS edge (the
  # transport deliberately does not decode).
  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp headers_for(extra) do
    bearer =
      case Process.get({__MODULE__, :token}) do
        nil -> []
        tok -> [{"authorization", "Bearer " <> tok}]
      end

    extra = List.wrap(extra)
    has_ct = Enum.any?(extra, fn {k, _} -> String.downcase(k) == "content-type" end)
    default = if has_ct, do: [], else: [{"content-type", "application/json"}]
    default ++ extra ++ bearer
  end
end
