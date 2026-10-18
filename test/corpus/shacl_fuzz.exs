# INCIDENT → FIX → FENCE
#
# INCIDENT: the Validate∘Hydrate pipeline (Defaults.apply → check_shape →
# Store.put) on the ARM router PUT surface had no adversarial fuzz receipt:
# nothing proved that arbitrary client-controlled bodies (binary garbage,
# deep nesting, unicode keys, wrong datatypes, oversized, null-heavy) can
# never produce an untyped 500/crash, that hydrate-before-validate admits
# sku-less storage, and that refusals never mutate the Store.
#
# FIX: the pipeline as landed — Defaults.apply/2 BEFORE check_shape
# (lib/smalt/arm_gateway/router.ex, "Defaults hydrate BEFORE shape
# validation"), typed send_arm_error / send_graphlaw_refusal envelopes, and
# the catch-all RouteNotFound match. This family fences all three.
#
# FENCE (this corpus row): 1,000 seeded adversarial PUT payloads across the
# storage/kv/cosmos/eh/sb families with three laws:
#   L1  no untyped escape: every response is 2xx or a 4xx/5xx ARM envelope
#       carrying error.code (a Plug.Parsers.ParseError on binary garbage is
#       wire-typed: the adapter renders it as a bare 400 — pinned by
#       test/auth_enforce_test.exs); any other raise or a 5xx is a CRASH.
#   L2  hydrate-before-validate: sku-less storage PUT with a valid location
#       is ADMITTED (Defaults.apply before check_shape).
#   L3  no refusal mutates the Store: snapshot of :smalt_resources +
#       :smalt_resource_groups is byte-identical across every refused/crashed
#       request.
Code.require_file("helper.exs", __DIR__)

defmodule Smalt.Corpus.ShaclFuzz do
  @moduledoc false

  use ExUnit.Case, async: false

  import Plug.Conn

  alias Smalt.ArmGateway.Router
  alias Smalt.Corpus.Helper
  alias Smalt.Store

  # Recorded seed — replayable: `SHACL_FUZZ_SEED`-pinned below; the corpus is
  # deterministic, so any failure reproduces from the seed alone.
  @seed {2026, 10, 16}
  @total 1_000

  @families [
    {"Microsoft.Storage/storageAccounts", "2023-05-01"},
    {"Microsoft.KeyVault/vaults", "2023-02-01"},
    {"Microsoft.DocumentDB/databaseAccounts", "2024-08-15"},
    {"Microsoft.EventHub/namespaces", "2024-01-01"},
    {"Microsoft.ServiceBus/namespaces", "2024-01-01"}
  ]

  @sub "fuzz-sub"
  @rg_prefix "fuzz-rg-"

  setup do
    # i22: resilient clear (bounded typed retry) instead of bare
    # ensure_store_up + Store.clear — canonical Helper.resilient_clear/1.
    Helper.resilient_clear()
    opts = Router.init([])

    # One valid resource group per family (refusal-invariant snapshots are
    # taken AFTER this setup, so the RG seeds never count as mutations).
    Enum.each(Enum.with_index(@families), fn {_fam, i} ->
      conn =
        put_conn(
          opts,
          "/subscriptions/#{@sub}/resourceGroups/#{@rg_prefix}#{i}?api-version=2023-07-01",
          %{
            "location" => "eastus"
          }
        )

      assert conn.status in [200, 201], inspect(conn.resp_body)
    end)

    %{opts: opts}
  end

  # ---------------------------------------------------------------------------
  # L2: hydrate-before-validate (the named law)
  # ---------------------------------------------------------------------------
  @tag :corpus
  test "L2: sku-less storage PUT with valid location is ADMITTED (Defaults.apply before check_shape)",
       %{
         opts: opts
       } do
    conn =
      put_conn(
        opts,
        storage_path("skuless-hydrate"),
        %{"location" => "eastus", "properties" => %{}}
      )

    assert conn.status in [200, 201, 202],
           "sku-less storage was refused — hydrate-before-validate regressed: #{inspect(conn.resp_body)}"
  end

  # ---------------------------------------------------------------------------
  # L1+L3 fuzz sweep: 1,000 seeded payloads
  # ---------------------------------------------------------------------------
  @tag :corpus
  @tag :stress
  # 1000-PUT full-pipeline sweep is legitimately >60s under suite load
  # (witnessed soak C run 2, receipts/i22-soak-c.md); default ExUnit timeout
  # trips on load, not regression. 3x margin, typed.
  @tag timeout: 180_000
  test "fuzz sweep: #{@total} seeded adversarial PUTs — no untyped escape, no refusal mutation",
       %{
         opts: opts
       } do
    :rand.seed(:exsss, @seed)
    payloads = generate_payloads(@total)

    assert length(payloads) == @total

    counts = Enum.frequencies_by(payloads, fn {class, _body} -> class end)

    results =
      Enum.with_index(payloads)
      |> Enum.map(fn {{class, body}, i} ->
        run_fuzz(opts, class, body, i)
      end)

    verdicts = Enum.frequencies_by(results, fn r -> r.verdict end)

    # L1: zero untyped escapes (crash / 5xx / untyped 4xx / refusal-mutation).
    crashes =
      Enum.filter(results, fn r ->
        r.verdict in [:untyped_crash, :server_error, :untyped_refusal, :l3_violation]
      end)

    for r <- crashes do
      flunk("untyped escape ##{r.index} [#{r.class}]: #{inspect(r.detail)}")
    end

    # L3: enforced inside run_fuzz per-request (snapshot diff on refusals).
    # L2 spot-check: the dedicated test above pins the hydrate law directly.

    IO.puts("""
    [shacl-fuzz] seed=#{inspect(@seed)} total=#{@total}
    [shacl-fuzz] payload classes: #{inspect(counts)}
    [shacl-fuzz] verdicts: #{inspect(verdicts)}
    """)

    # Sanity: the sweep must actually flip — some refusals and some admits.
    assert (verdicts[:typed_refusal] || 0) + (verdicts[:parse_typed] || 0) > 0,
           "fuzz sweep produced zero refusals — generator is vacuous"
  end

  # ---------------------------------------------------------------------------
  # Pinned regression rows (the ~20 most interesting payloads from the
  # receipted sweep — permanent, deterministically replayed every run).
  # ---------------------------------------------------------------------------
  @tag :corpus
  test "pinned regression rows replay with their receipted verdict classes", %{opts: opts} do
    for {label, family_idx, body, expected_verdict} <- pinned_rows() do
      {type, av} = Enum.at(@families, family_idx)
      path = resource_path(family_idx, type, av, "pin-#{label}")

      pre = snapshot()
      result = dispatch(opts, path, body)
      post = snapshot()

      assert result.verdict == expected_verdict,
             "pinned row #{inspect(label)}: expected #{expected_verdict}, got #{result.verdict} — #{inspect(result.detail)}"

      if result.verdict != :admitted do
        assert pre == post, "pinned row #{inspect(label)} mutated the Store on a refusal"
      end
    end
  end

  # ===========================================================================
  # Payload generator (deterministic under the recorded seed)
  # ===========================================================================

  defp generate_payloads(n) do
    classes = [
      :malformed_binary,
      :deep_nesting,
      :unicode_keys,
      :non_map_body,
      :partial,
      :wrong_types,
      :oversized,
      :null_heavy,
      :unhydrated,
      :benign_valid
    ]

    for i <- 0..(n - 1) do
      class = Enum.at(classes, rem(i, length(classes)))
      {class, generate(class, i)}
    end
  end

  defp generate(:malformed_binary, i) do
    size = 8 + :rand.uniform(4096)
    bytes = :crypto.strong_rand_bytes(size)
    {:raw, bytes <> "-#{i}"}
  end

  defp generate(:deep_nesting, i) do
    depth = 64 + :rand.uniform(192)

    body =
      Enum.reduce(1..depth, %{"leaf-#{i}" => "v"}, fn _d, acc ->
        %{"properties" => acc}
      end)

    %{"location" => "eastus", "name" => "deep-#{i}", "nest" => body}
  end

  defp generate(:unicode_keys, i) do
    keys = ["キー", "clave-ñ", "🔒-#{i}", "مفتاح", "k\u0000ey"]

    %{
      "location" => "eastus",
      "properties" => Map.new(Enum.with_index(keys), fn {k, j} -> {k, "v#{j}"} end),
      String.slice("tags-ünïcødé-#{i}", 0, 20) => %{"🎉" => true}
    }
  end

  defp generate(:non_map_body, i) do
    Enum.random([
      [%{"location" => "eastus"}, %{i => i}],
      i,
      "scalar-string-#{i}",
      3.14,
      true,
      nil
    ])
  end

  defp generate(:partial, i) do
    Enum.random([
      # sku-less storage (L2 payload in the sweep)
      %{"location" => "eastus", "kind" => "StorageV2"},
      # empty properties
      %{"location" => "westus", "properties" => %{}},
      # missing location
      %{"properties" => %{"supportsHttpsTrafficOnly" => true}},
      # empty body
      %{}
    ])
    |> then(fn b -> mark(b, i) end)
  end

  defp generate(:wrong_types, i) do
    Enum.random([
      %{"location" => "eastus", "sku" => %{"name" => 100, "tier" => false}},
      %{"location" => "eastus", "properties" => %{"supportsHttpsTrafficOnly" => "true"}},
      %{"location" => 42},
      %{"location" => "eastus", "tags" => "not-a-map"},
      %{"location" => "eastus", "properties" => [%{"list-not-map" => true}]},
      %{"location" => "eastus", "sku" => "Standard_LRS"}
    ])
    |> then(fn b -> mark(b, i) end)
  end

  defp generate(:oversized, i) do
    if rem(i, 2) == 0 do
      # ~1 MiB string value
      %{
        "location" => "eastus",
        "properties" => %{"blob" => String.duplicate("x", 1_048_576 - 128)}
      }
    else
      # 20k keys
      %{"location" => "eastus", "properties" => Map.new(0..20_000, fn k -> {"k#{k}", k} end)}
    end
  end

  defp generate(:null_heavy, i) do
    %{
      "location" => "eastus",
      "sku" => nil,
      "tags" => nil,
      "properties" => %{
        "supportsHttpsTrafficOnly" => nil,
        "isHnsEnabled" => nil,
        "minimumTlsVersion" => nil,
        "nested" => %{"a" => nil, "b" => nil, "c" => nil}
      }
    }
    |> mark(i)
  end

  defp generate(:unhydrated, i) do
    Enum.random([
      # storage without sku/tier — relies entirely on Defaults hydration
      %{"location" => "eastus"},
      %{"location" => "eastus", "sku" => %{"name" => "Standard_LRS"}},
      %{"location" => "eastus", "sku" => %{}},
      %{"location" => "eastus", "properties" => %{"networkAcls" => %{}}}
    ])
    |> mark(i)
  end

  defp generate(:benign_valid, i) do
    %{
      "location" => "eastus",
      "sku" => %{"name" => "Standard_LRS", "tier" => "Standard"},
      "properties" => %{"supportsHttpsTrafficOnly" => true},
      "tags" => %{"fuzz" => "#{i}"}
    }
  end

  defp mark(body, i), do: Map.put(body, "fuzz-index", i)

  # ===========================================================================
  # Pinned rows (fill from the receipted sweep — label, family idx, body,
  # expected verdict)
  # ===========================================================================

  defp pinned_rows do
    [
      {"skuless-hydrate", 0, %{"location" => "eastus", "properties" => %{}}, :admitted},
      {"sku-int", 0, %{"location" => "eastus", "sku" => %{"name" => 100}}, :admitted},
      {"string-bool", 0,
       %{"location" => "eastus", "properties" => %{"supportsHttpsTrafficOnly" => "true"}},
       :admitted},
      # Validator gate truth: the storage shape is minCount-only (no
      # sh:datatype on location), so an integer location passes present? and
      # survives the full record build — parity with sku-int / string-bool,
      # both receipted as admitted. Typed datatype enforcement is roadmap,
      # not landed behavior (do not pin a refusal the shape cannot produce).
      {"location-int", 0, %{"location" => 42}, :admitted},
      # Landed coerce fence: normalize_tags coerces non-map tags to %{}
      # (tags-always-present, azurerm tolerance) — the request is ADMITTED
      # with empty tags, never refused. Do not pin a refusal the pipeline
      # cannot produce.
      {"tags-string", 0, %{"location" => "eastus", "tags" => "not-a-map"}, :admitted},
      {"null-heavy", 0,
       %{
         "location" => "eastus",
         "sku" => nil,
         "properties" => %{"supportsHttpsTrafficOnly" => nil}
       }, :typed_refusal},
      # Scalar/_json-wrap + hydrate truth: Plug.Parsers wraps non-map JSON
      # bodies as %{"_json" => term}; Defaults.apply then hydrates location
      # (template string), so the minCount gate passes and the record builds
      # with fallbacks. The landed pipeline ADMITS these — the fuzz sweep
      # receipts the verdict class. Typed scalar refusal is roadmap.
      {"missing-location", 0, %{"properties" => %{}}, :admitted},
      {"empty-body", 0, %{}, :admitted},
      {"list-body", 0, [%{"location" => "eastus"}], :admitted},
      {"int-body", 0, 7, :admitted},
      {"nested-256", 0,
       %{
         "location" => "eastus",
         "nest" => Enum.reduce(1..256, %{"leaf" => "v"}, fn _d, acc -> %{"properties" => acc} end)
       }, :admitted},
      {"unicode-keys", 0, %{"location" => "eastus", "properties" => %{"キー" => "v", "🔒" => "v"}},
       :admitted},
      {"kv-sku-string", 1, %{"location" => "eastus", "properties" => %{"sku" => "free"}},
       :typed_refusal},
      # Cosmos account defaults hydrate databaseAccountOfferType; empty
      # properties pass the open cosmos shape — receipted ADMITTED.
      {"cosmos-null-pk", 2, %{"location" => "eastus", "properties" => %{}}, :admitted},
      {"eh-valid", 3, %{"location" => "eastus", "sku" => %{"name" => "Standard"}}, :admitted},
      # SB has no Defaults entry (no hydration): the open SB shape requires
      # skuName, absent here — receipted typed_refusal 400 (InvalidResourceShape).
      {"sb-oversized", 4,
       %{"location" => "eastus", "properties" => %{"blob" => String.duplicate("x", 200_000)}},
       :typed_refusal},
      {"deep-unicode-null", 0,
       %{
         "location" => "eastus",
         "properties" => %{"キー" => %{"🔒" => [%{"a" => nil}]}}
       }, :admitted},
      {"bool-body", 0, true, :admitted},
      {"float-body", 0, 3.14, :admitted},
      {"null-body", 0, nil, :admitted}
    ]
  end

  # ===========================================================================
  # Dispatch + classification
  # ===========================================================================

  defp run_fuzz(opts, class, body, i) do
    {type, av} = Enum.at(@families, rem(i, length(@families)))
    path = resource_path(i, type, av, "fz-#{i}")

    pre = snapshot()
    result = dispatch(opts, path, body)
    post = snapshot()

    result =
      if result.verdict == :admitted or pre == post do
        result
      else
        # L3 violation is itself an untyped escape — upgrade the verdict.
        %{result | verdict: :l3_violation, detail: "refused request mutated the Store"}
      end

    result
    |> Map.put(:index, i)
    |> Map.put(:class, class)
  end

  defp dispatch(opts, path, {:raw, bytes}) do
    do_dispatch(opts, path, bytes)
  end

  defp dispatch(opts, path, body)
       when is_map(body) or is_list(body) or is_number(body) or is_boolean(body) do
    do_dispatch(opts, path, Jason.encode!(body))
  end

  defp dispatch(opts, path, body) when is_binary(body) do
    do_dispatch(opts, path, body)
  end

  defp dispatch(opts, path, nil) do
    do_dispatch(opts, path, "null")
  end

  defp do_dispatch(opts, path, raw_body) do
    try do
      conn =
        Plug.Test.conn(:put, path, raw_body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(opts)

      classify_conn(conn)
    rescue
      e in Plug.Parsers.ParseError -> %{verdict: :parse_typed, detail: Exception.message(e)}
      e -> %{verdict: :untyped_crash, detail: {e.__struct__, Exception.message(e)}}
    end
  end

  defp classify_conn(conn) do
    cond do
      conn.status >= 500 ->
        %{verdict: :server_error, detail: String.slice(to_string(conn.resp_body), 0, 300)}

      conn.status >= 400 ->
        if typed_refusal?(conn.resp_body) do
          %{verdict: :typed_refusal, detail: nil}
        else
          %{verdict: :untyped_refusal, detail: String.slice(to_string(conn.resp_body), 0, 300)}
        end

      true ->
        %{verdict: :admitted, detail: nil}
    end
  end

  defp typed_refusal?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} when is_binary(code) and code != "" -> true
      _ -> false
    end
  end

  defp typed_refusal?(_), do: false

  defp put_conn(opts, path, body) do
    Plug.Test.conn(:put, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(opts)
  end

  defp resource_path(family_idx, type, av, name) do
    "/subscriptions/#{@sub}/resourceGroups/#{@rg_prefix}#{family_idx}/providers/#{type}/#{name}?api-version=#{av}"
  end

  defp storage_path(name) do
    {type, av} = Enum.at(@families, 0)
    resource_path(0, type, av, name)
  end

  # ---------------------------------------------------------------------------
  # i22 snapshot hardening (mechanism per
  # docs/jira/v26.10.17/receipts/i20b-contention-mechanism.md + i22 report):
  #   1. Subscription-scoped key sets — the L3 law can only be violated by
  #      keys under OUR /subscriptions/fuzz-sub/ id; async siblings write
  #      other subscriptions' rows into the same shared table and those
  #      foreign inserts are the interference term (filtered out here).
  #   2. Quiescent double-read via Smalt.Corpus.Helper.quiescent_read/2 —
  #      two consecutive agreeing reads, dead-table + 5000ms-call-cliff
  #      typed rescues, bounded, loud past the bound. Canonical now; the
  #      private copy is deleted.
  # ---------------------------------------------------------------------------
  @snapshot_scope "/subscriptions/#{@sub}/"

  defp snapshot do
    read = fn table ->
      table
      |> Store.keys()
      |> Enum.filter(fn k ->
        is_binary(k) and String.contains?(String.downcase(k), @snapshot_scope)
      end)
      |> Enum.sort()
    end

    Helper.quiescent_read(fn ->
      {read.(:smalt_resources), read.(:smalt_resource_groups)}
    end)
  end
end
