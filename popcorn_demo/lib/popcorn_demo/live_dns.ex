defmodule PopcornDemo.LiveDns do
  @moduledoc """
  X8 — ARM control-plane breadth leg: Microsoft.Network/privateDnsZones
  (KD-29 witnessed face) over REAL state (Chicago testbed: real
  collaborators, real substrate, no mocks).

  One `run/0` walks the private-DNS face on the live control plane
  (`http://127.0.0.1:9443`):

    1. mint an STS bearer at `POST /{tenant}/oauth2/v2.0/token`
       (audience https://management.azure.com/.default)
    2. ensure RG `popcorn-rg` via ARM PUT
    3. PUT private DNS zone `dns-x8-<unix>` (run-unique) via the generic
       3-segment provider resource PUT (registry.ex:43 admits
       "Microsoft.Network/privateDnsZones", api-version pin registry.ex:132
       = "2018-09-01")
    4. PUT + GET a `virtualNetworkLinks` child (the KD-29 witness face,
       router.ex:4909/:4921 handle_parented_child)
    5. PUT an A record set inside the zone — WITNESSED ABSENT: the
       record-set routes (router.ex:2596) are declared for the literal
       `dnsZones` family only; `privateDnsZones/:zone/:rtype/:rname`
       answers 404 RouteNotFound (live probe, 2026-10-20). The probe is
       surfaced typed (`{:route_absent, 404, "RouteNotFound"}`); run/0
       returns the loud refusal below. Cleanup still deletes the zone.
    6. DELETE zone (200) then re-GET (404) — real deletion, real absence.

  Wire seam (receipt): lib/smalt/arm_gateway/router.ex:4909/:4921
  (virtualNetworkLinks via handle_parented_child) / generic 3-segment PUT
  for the zone itself / :2596 record-set family (dnsZones literal only).

  Receipts (run/0 return), house style:
    {:ok,    "dns=OK(<zone>:<records>)"}
    {:skip,  "dns=SKIP(transport:<reason>)"}          -- substrate down
    {:error, "dns=FAIL(<step>:<reason>)"}             -- any other failure
    {:error, "dns=UNSUPPORTED(recordset-A:<reason>)"} -- record face absent,
       loud and typed, never a silent skip.

  Transport: BK-15 Fetch port (2026-10-21) — Fetch under the Popcorn JS
  bridge, `Transport.Httpc` on host (single
  calculus, ERRC-E2), raw binary bodies JSON-decoded at THIS module's edge
  (`decode_body/1`).

  Not wired into the supervision tree — coordinator integrates.
  Export `run/0` plus test seams only.
  """

  @base "http://127.0.0.1:9443"
  @tenant "00000000-0000-0000-0000-000000000000"
  @scope "https://management.azure.com/.default"
  @api "api-version=2018-09-01"

  @sub_id "popcorn-rg-sub"
  @rg "popcorn-rg"
  @zone_type "Microsoft.Network/privateDnsZones"

  @rg_base "/subscriptions/#{@sub_id}/resourceGroups/#{@rg}"
  @zones_base "#{@rg_base}/providers/Microsoft.Network/privateDnsZones"

  @doc "Full walk: RG + private zone PUT + vNetLink PUT/GET + A-recordset probe + DELETE + 404."
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    zone = "dns-x8-#{System.system_time(:second)}"

    with :ok <- mint(),
         :ok <- ensure_rg(),
         :ok <- put_zone(zone),
         :ok <- put_and_get_vnet_link(zone),
         probe <- probe_recordset(zone),
         :ok <- delete_zone(zone),
         :ok <- assert_zone_gone(zone) do
      case probe do
        # Typed loud refusal: the A-recordset face under privateDnsZones
        # does not exist on this substrate (404 RouteNotFound). Cleanup
        # succeeded; the walk did NOT silently pass.
        {:route_absent, st, code} ->
          {:error, "dns=UNSUPPORTED(recordset-A:#{code}-#{st}-zone-deleted-clean)"}

        {:ok, n} ->
          {:ok, "dns=OK(#{zone}:#{n}-records)"}
      end
    else
      {:error, _} = done -> done
      {:skip, _} = done -> done
    end
  end

  # -- Steps ---------------------------------------------------------------

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
        {:error, "dns=FAIL(mint:STS-status-#{s}-body=#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp ensure_rg do
    case arm_req(:put, @rg_base, %{"location" => "eastus", "properties" => %{}}) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "dns=FAIL(ensure_rg:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp put_zone(zone) do
    body = %{"location" => "global", "properties" => %{}}

    case arm_req(:put, "#{@zones_base}/#{zone}", body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "dns=FAIL(put_zone:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  # KD-29 witness face: privateDnsZones/virtualNetworkLinks via
  # handle_parented_child (router.ex:4909 PUT / :4921 GET).
  defp put_and_get_vnet_link(zone) do
    link = "x8-link"
    base = "#{@zones_base}/#{zone}/virtualNetworkLinks"
    body = %{"location" => "global", "properties" => %{"virtualNetwork" => %{"id" => "x8-vnet"}}}

    with {:ok, %{status: s}} when s in [200, 201] <-
           arm_req(:put, "#{base}/#{link}", body),
         {:ok, %{status: 200, body: %{"name" => ^link}}} <-
           arm_req(:get, "#{base}/#{link}") do
      :ok
    else
      {:ok, %{status: s, body: b}} ->
        {:error, "dns=FAIL(vnet_link:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  # The record-set slice. Returns {:ok, n} when the face is live,
  # {:route_absent, status, code} when the ROUTE does not exist
  # (distinguished from resource absence by the ARM error code on the
  # body), or a FAIL/SKIP.
  @spec probe_recordset(binary()) ::
          {:ok, non_neg_integer()}
          | {:route_absent, pos_integer(), binary()}
          | {:error, binary()}
          | {:skip, binary()}
  def probe_recordset(zone) do
    record_body = %{
      "properties" => %{"ttl" => 300, "aRecords" => [%{"ipv4Address" => "10.1.2.3"}]}
    }

    case arm_req(:put, "#{@zones_base}/#{zone}/A/host", record_body) do
      {:ok, %{status: s}} when s in [200, 201] ->
        case arm_req(:get, "#{@zones_base}/#{zone}/A/host") do
          {:ok, %{status: 200, body: %{"properties" => %{"aRecords" => recs}}} = rec}
          when is_list(recs) ->
            if hd(recs)["ipv4Address"] == "10.1.2.3" and rec["name"] == "host" do
              {:ok, 1}
            else
              {:error, "dns=FAIL(recordset_get:echo-mismatch-#{slice(recs)})"}
            end

          {:ok, %{status: s, body: b}} ->
            {:error, "dns=FAIL(recordset_get:HTTP-#{s}-#{slice(b)})"}

          {:error, reason} ->
            {:skip, "dns=SKIP(transport:#{slice(reason)})"}
        end

      # Route absence: the ARM error code names it (RouteNotFound = the
      # route itself is not registered, vs NotFound = missing resource).
      {:ok, %{status: 404, body: %{"error" => %{"code" => code}}}} when code != "NotFound" ->
        {:route_absent, 404, code}

      {:ok, %{status: s, body: b}} ->
        {:error, "dns=FAIL(recordset_put:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  defp delete_zone(zone) do
    case arm_req(:delete, "#{@zones_base}/#{zone}") do
      {:ok, %{status: s}} when s in [200, 204] ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "dns=FAIL(delete_zone:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  # Real absence: the re-GET must answer 404 AFTER the delete.
  defp assert_zone_gone(zone) do
    case arm_req(:get, "#{@zones_base}/#{zone}") do
      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        {:error, "dns=FAIL(assert_zone_gone:HTTP-#{s}-#{slice(b)})"}

      {:error, reason} ->
        {:skip, "dns=SKIP(transport:#{slice(reason)})"}
    end
  end

  # -- Wire seam + pure-slice helpers (public for the Chicago test) ----------

  @doc "ARM path of a private zone (test seam)."
  def zone_path(zone), do: "#{@zones_base}/#{zone}"

  @doc "Admitted ARM type under test (registry.ex pin)."
  def zone_type, do: @zone_type

  @doc "api-version pin (registry.ex:132, 2018-09-01)."
  def api_version, do: "2018-09-01"

  @doc "Real HTTP PUT of the private zone over the live substrate (test seam)."
  def put_zone_seam(zone) do
    with :ok <- mint(),
         :ok <- ensure_rg() do
      put_zone(zone)
    end
  end

  @doc "Real HTTP GET of a private zone (test seam), raw transport result."
  def get_zone_seam(zone) do
    with :ok <- mint() do
      arm_req(:get, "#{@zones_base}/#{zone}")
    end
  end

  @doc "Real HTTP DELETE of a private zone (test seam), raw transport result."
  def delete_zone_seam(zone) do
    with :ok <- mint() do
      case arm_req(:delete, "#{@zones_base}/#{zone}") do
        {:ok, %{status: _s}} = ok ->
          ok

        {:ok, %{status: s, body: b}} ->
          {:error, "dns=FAIL(delete_zone:HTTP-#{s}-#{slice(b)})"}

        {:error, reason} ->
          {:skip, "dns=SKIP(transport:#{slice(reason)})"}
      end
    end
  end

  @doc "Typed record-set probe (test seam): raw typed result, no cleanup."
  def probe_recordset_seam(zone) do
    with :ok <- mint() do
      probe_recordset(zone)
    end
  end

  @doc """
  Tokenless negative (test seam): real GET with NO bearer. In enforce mode
  the control plane must answer 401 (KD-15 challenge handshake shape;
  Transport surfaces `{status, headers, body}` — refusal witnessed at
  header level).
  """
  def fetch_tokenless(zone \\ "dns-x8-tokenless-probe") do
    Process.delete({__MODULE__, :token})
    req(:get, "#{@base}#{zone_path(zone)}?#{@api}")
  end

  # -- Transport ------------------------------------------------------------

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

  defp req(method, url, opts \\ []) do
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

    # BK-15 Fetch port (2026-10-21): former hardcoded Httpc pipe crashed in the
    # wasm BEAM (:httpc unavailable) — dns=SKIP(wasm-transport...). Now the
    # kv=OK precedent: Transport.Fetch under the Popcorn JS bridge, Httpc on host.
    result =
      if browser?() do
        PopcornDemo.Transport.Fetch.request(request)
      else
        PopcornDemo.Transport.Httpc.request(request)
      end

    result |> decode_body()
  end

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

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
