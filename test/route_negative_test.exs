defmodule SmaltRouteNegativeTest do
  @moduledoc """
  Negative-path route tests for `Smalt.ArmGateway.Router` (Plug.Test, in-process).

  Pinned ARM behaviors:
    * unknown path -> 404 with a MAP-shaped `error` object
    * missing api-version on a provider PUT -> 400 `MissingApiVersionParameter`
    * bad api-version on an admitted type -> 400 `InvalidApiVersionParameter`
    * PUT of an unadmitted type -> 400 GraphLaw refusal envelope
      (code `InvalidResourceShape`, target `AshGraphLaw.Enforcement`)
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])

  setup do
    ensure_store()
    Store.clear()
    :ok
  end

  test "unknown path -> 404 with a map-shaped error envelope" do
    conn =
      conn(:get, "/definitely/not/a/route")
      |> Router.call(@opts)

    assert conn.status == 404

    body = Jason.decode!(conn.resp_body)
    assert is_map(body["error"])
    assert is_binary(body["error"]["code"])
    assert is_binary(body["error"]["message"])
  end

  test "provider PUT without api-version -> 400 MissingApiVersionParameter" do
    conn =
      conn(
        :put,
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1",
        %{
          "location" => "smalt-local"
        }
      )
      |> Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "MissingApiVersionParameter"
  end

  test "provider PUT with bad api-version -> 400 InvalidApiVersionParameter" do
    path =
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1?api-version=2999-01-01"

    conn =
      conn(:put, path, %{"location" => "smalt-local"})
      |> Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidApiVersionParameter"
    assert body["error"]["message"] =~ "2999-01-01"
  end

  test "PUT of an unadmitted type -> 400 GraphLaw refusal envelope" do
    path =
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Fake/things/thing-1?api-version=2021-04-01"

    conn =
      conn(:put, path, %{"location" => "smalt-local"})
      |> Router.call(@opts)

    assert conn.status == 400

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidResourceShape"
    assert body["error"]["target"] == "AshGraphLaw.Enforcement"
    assert is_binary(body["error"]["message"])
  end

  # ===========================================================================
  # Lens-2 coverage-audit fence: the generic provider LIST and DELETE routes
  # and the subscription-level provider inventory all require api-version,
  # same as PUT/GET (RG-parity, cycle-7 landing extended to every matched
  # route). 404-vs-400 precedence pinned: api-version 400 fires BEFORE any
  # store lookup (empty store — no parent, no record — yet the response is
  # the 400 envelope, not 404 ResourceNotFound/RouteNotFound).
  # ===========================================================================

  test "generic provider LIST without api-version -> 400 MissingApiVersionParameter (400 before 404)" do
    conn =
      conn(
        :get,
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts"
      )
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test "generic provider LIST with stale api-version -> 400 InvalidApiVersionParameter" do
    conn =
      conn(
        :get,
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts?api-version=2999-01-01"
      )
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidApiVersionParameter"
  end

  test "generic provider DELETE without api-version -> 400 MissingApiVersionParameter (400 before 404)" do
    conn =
      conn(
        :delete,
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1"
      )
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test "generic provider DELETE with stale api-version -> 400 InvalidApiVersionParameter" do
    conn =
      conn(
        :delete,
        "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Storage/storageAccounts/acct1?api-version=2999-01-01"
      )
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidApiVersionParameter"
  end

  test "subscription-level providers inventory without api-version -> 400 MissingApiVersionParameter" do
    conn =
      conn(:get, "/subscriptions/sub-1/providers")
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test "subscription list without api-version -> 400 MissingApiVersionParameter (400 before 200, empty store)" do
    conn =
      conn(:get, "/subscriptions")
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test "subscription read without api-version -> 400 MissingApiVersionParameter (400 before 404 on unknown sub)" do
    conn =
      conn(:get, "/subscriptions/sub-does-not-exist")
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test "type-scoped LIST does not leak deep-type descendants (real-ARM parity)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    sa_v = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

    c_v =
      Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers")

    Store.put(
      :smalt_resources,
      String.downcase(rg <> "/providers/microsoft.storage/storageaccounts/st-1"),
      %{
        "id" => rg <> "/providers/Microsoft.Storage/storageAccounts/st-1",
        "type" => "Microsoft.Storage/storageAccounts",
        "name" => "st-1",
        "location" => "eastus",
        "properties" => %{},
        "tags" => %{},
        "systemData" => %{}
      }
    )

    # A providers-shaped deep-type record (the only shape that can physically
    # share the generic LIST prefix). Real child PUTs store WITHOUT the
    # /providers segment (handle_child_put rel_path shape), so they never
    # reach this prefix — the filter pins the hostile/misshapen case only.
    Store.put(
      :smalt_resources,
      String.downcase(
        rg <>
          "/providers/microsoft.storage/storageaccounts/st-1/blobservices/default/containers/c-1"
      ),
      %{
        "id" =>
          rg <>
            "/providers/Microsoft.Storage/storageAccounts/st-1/blobServices/default/containers/c-1",
        "type" => "Microsoft.Storage/storageAccounts/blobServices/containers",
        "name" => "c-1",
        "location" => "eastus",
        "properties" => %{},
        "tags" => %{},
        "systemData" => %{}
      }
    )

    conn =
      conn(:get, rg <> "/providers/Microsoft.Storage/storageAccounts?api-version=#{sa_v}")
      |> Router.call(@opts)

    assert conn.status == 200

    names =
      Jason.decode!(conn.resp_body)["value"]
      |> MapSet.new(& &1["name"])

    # The storageAccount page contains ONLY storageAccounts — the deep-type
    # record must not leak into the parent type's page (real ARM returns only
    # the requested resourceType from a type-scoped LIST).
    assert MapSet.equal?(names, MapSet.new(["st-1"]))

    # Real child flow: a child-PUT-shaped record (no /providers segment) is
    # listable under its own deep-type route (child-resource route parity).
    Store.put(
      :smalt_resources,
      String.downcase(rg <> "/storageaccounts/st-1/blobservices/default/containers/c-2"),
      %{
        "id" => rg <> "/storageAccounts/st-1/blobServices/default/containers/c-2",
        "type" => "Microsoft.Storage/storageAccounts/blobServices/containers",
        "name" => "c-2",
        "location" => "eastus",
        "properties" => %{},
        "tags" => %{},
        "systemData" => %{}
      }
    )

    conn2 =
      conn(
        :get,
        rg <>
          "/providers/Microsoft.Storage/storageAccounts/st-1/blobServices/default/containers?api-version=#{c_v}"
      )
      |> Router.call(@opts)

    assert conn2.status == 200
    assert [%{"name" => "c-2"}] = Jason.decode!(conn2.resp_body)["value"]
  end

  # Lens-4 cycle 2 (F1a): the LIVE child flow cannot produce the misshapen
  # providers-shaped deep-type key. The containers PUT matches the explicit
  # child route, whose handle_child_put key omits the /providers literal —
  # so the record lands OUTSIDE the generic type-scoped LIST prefix scan.
  test "live child PUT stores without a /providers key segment (leak filter is defense-in-depth)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"

    c_v =
      Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers")

    conn =
      conn(
        :put,
        rg <>
          "/providers/Microsoft.Storage/storageAccounts/st-1/blobServices/default/containers/wire-1" <>
          "?api-version=#{c_v}",
        %{"location" => "eastus"}
      )
      |> Router.call(@opts)

    assert conn.status == 201

    # The record exists under the child-flow key (no /providers segment) and
    # nothing — not even the new record — landed under the providers prefix.
    assert [%{"name" => "wire-1"}] =
             Store.list_prefix(:smalt_resources, String.downcase(rg <> "/storageaccounts/"))

    assert Store.list_prefix(:smalt_resources, String.downcase(rg <> "/providers/")) == []
  end

  # Lens-4 cycle 2 (F1b): a deep-type PUT falls through to 404 WITHOUT any
  # store write — no in-repo route can create the misshapen providers-shaped
  # deep-type key the filter guards against. virtualNetworkLinks now has a
  # dedicated parented-child route, so the refusal is parent-gated
  # (ResourceNotFound) instead of fall-through (RouteNotFound); either code
  # satisfies the law — the load-bearing fence is the zero-store-write assert.
  test "unrouted deep-type PUT 404s without a store write (filter is defense-in-depth)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"

    # api-version MUST be the registry's latest for the type (2018-09-01):
    # the refusal-tier chain (api-version → admission → shape → properties)
    # fires BEFORE the parent-existence 404, so a stale api-version now
    # answers 400, not 404 — that tiering is asserted in the refusal sweep.
    conn =
      conn(
        :put,
        rg <>
          "/providers/Microsoft.Network/privateDnsZones/pz-1/virtualNetworkLinks/link-1" <>
          "?api-version=#{Smalt.Registry.latest_version("Microsoft.Network/privateDnsZones/virtualNetworkLinks")}",
        %{"location" => "eastus"}
      )
      |> Router.call(@opts)

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body)["error"]["code"] in ["RouteNotFound", "ResourceNotFound"]
    assert Store.list_prefix(:smalt_resources, String.downcase(rg <> "/")) == []
  end

  # Lens-4 cycle 2 (F2): the parity filter composes with nextLink pagination.
  # The filter runs BEFORE send_list on every request, and $skip slices the
  # already-filtered list, so a followed nextLink must return a page that
  # still honors the filter (real-ARM parity: filtering is not a page-1-only
  # side effect). 150 parent-type + 50 deep-type providers-shaped records are
  # seeded directly (the wire cannot produce this shape — see the F1 fence).
  test "type-scoped LIST filter composes with nextLink pagination (followed pages honor the filter)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    sa_v = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

    c_v =
      Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers")

    parent_names = for i <- 0..149, do: "st-#{i}"
    deep_names = for i <- 0..49, do: "c-#{i}"

    for name <- parent_names do
      Store.put(
        :smalt_resources,
        String.downcase(rg <> "/providers/microsoft.storage/storageaccounts/#{name}"),
        %{
          "id" => rg <> "/providers/Microsoft.Storage/storageAccounts/#{name}",
          "type" => "Microsoft.Storage/storageAccounts",
          "name" => name,
          "location" => "eastus",
          "properties" => %{},
          "tags" => %{},
          "systemData" => %{}
        }
      )
    end

    for name <- deep_names do
      Store.put(
        :smalt_resources,
        String.downcase(
          rg <>
            "/providers/microsoft.storage/storageaccounts/st-1/blobservices/default/containers/#{name}"
        ),
        %{
          "id" =>
            rg <>
              "/providers/Microsoft.Storage/storageAccounts/st-1/blobServices/default/containers/#{name}",
          "type" => "Microsoft.Storage/storageAccounts/blobServices/containers",
          "name" => name,
          "location" => "eastus",
          "properties" => %{},
          "tags" => %{},
          "systemData" => %{}
        }
      )
    end

    # Page 1: exactly @page_size (100) parent-type records, nextLink present.
    conn =
      conn(:get, rg <> "/providers/Microsoft.Storage/storageAccounts?api-version=#{sa_v}")
      |> Router.call(@opts)

    assert conn.status == 200
    page1 = Jason.decode!(conn.resp_body)
    assert length(page1["value"]) == 100
    assert Enum.all?(page1["value"], &(&1["name"] in parent_names))
    assert is_binary(page1["nextLink"])

    # Follow the returned nextLink verbatim (absolute URL; query must carry
    # api-version + $skip — the carry-through itself is fenced elsewhere).
    next = URI.parse(page1["nextLink"])
    assert next.query

    conn2 =
      conn(:get, next.path <> "?" <> next.query)
      |> Router.call(@opts)

    assert conn2.status == 200
    page2 = Jason.decode!(conn2.resp_body)

    # Page 2 honors the filter: 50 parent records, zero deep-type leaks.
    assert length(page2["value"]) == 50
    assert Enum.all?(page2["value"], &(&1["name"] in parent_names))
    refute Map.has_key?(page2, "nextLink")

    # The union of the filtered pages is exactly the parent population.
    all_names =
      (Enum.map(page1["value"], & &1["name"]) ++ Enum.map(page2["value"], & &1["name"]))
      |> Enum.sort()

    assert all_names == Enum.sort(parent_names)

    # maxitempages composition: 2 pages per response carries all 150 filtered
    # records in one response with no truncation.
    conn3 =
      conn(
        :get,
        rg <> "/providers/Microsoft.Storage/storageAccounts?api-version=#{sa_v}&maxitempages=2"
      )
      |> Router.call(@opts)

    assert conn3.status == 200
    merged = Jason.decode!(conn3.resp_body)
    assert length(merged["value"]) == 150
    assert Enum.all?(merged["value"], &(&1["name"] in parent_names))
    refute Map.has_key?(merged, "nextLink")
    _ = c_v
  end

  # Lens-5 cycle 1 (F3a): the nested-diagnostics glob is itself a child writer
  # that CAN land inside the providers prefix — a double-providers path
  # (…/providers/providers/Microsoft.Insights/diagnosticSettings/:name) matches
  # the glob with rel_path = "providers/Microsoft.Insights/diagnosticSettings/:name",
  # so handle_child_put stores at key rg/providers/microsoft.insights/
  # diagnosticsettings/:name — INSIDE the generic prefix scan. This refines the
  # lens-4 F1a claim scope (not every child writer avoids the providers
  # prefix), but parity still holds by construction: the glob only ever admits
  # the 2-segment type Microsoft.Insights/diagnosticSettings, and its key is
  # byte-identical to the generic 3-segment route's canonical key for the same
  # id — so the record is a first-class citizen of the matching type page
  # (filtered IN, not leaked), and no deep type can ever ride this writer.
  test "double-providers glob PUT lands a diagnosticSettings record inside the providers prefix (parity by type convergence)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    ds_v = Smalt.Registry.latest_version("Microsoft.Insights/diagnosticSettings")
    sa_v = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

    conn =
      conn(
        :put,
        rg <>
          "/providers/providers/Microsoft.Insights/diagnosticSettings/dsm-1?api-version=#{ds_v}",
        %{"location" => "eastus", "properties" => %{}}
      )
      |> Router.call(@opts)

    assert conn.status in [200, 201]

    # The record is stored INSIDE the providers prefix…
    stored = Store.list_prefix(:smalt_resources, String.downcase(rg <> "/providers/"))
    assert length(stored) == 1

    # …with the glob's only-possible 2-segment type and the generic route's
    # canonical key, so it is filtered INTO the matching type page, not leaked.
    assert hd(stored)["type"] == "Microsoft.Insights/diagnosticSettings"

    conn2 =
      conn(
        :get,
        rg <>
          "/providers/Microsoft.Insights/diagnosticSettings/dsm-1?api-version=#{ds_v}"
      )
      |> Router.call(@opts)

    assert conn2.status == 200

    # The generic route and the glob converge on the same record.
    assert Jason.decode!(conn2.resp_body)["name"] == "dsm-1"

    list_conn =
      conn(
        :get,
        rg <> "/providers/Microsoft.Insights/diagnosticSettings?api-version=#{ds_v}"
      )
      |> Router.call(@opts)

    assert list_conn.status == 200
    assert [%{"name" => "dsm-1"}] = Jason.decode!(list_conn.resp_body)["value"]

    # A foreign type page never sees it (the parity filter holds on this
    # writer's output too).
    seed_v = sa_v

    Store.put(
      :smalt_resources,
      String.downcase(rg <> "/providers/microsoft.storage/storageaccounts/st-0"),
      %{
        "id" => rg <> "/providers/Microsoft.Storage/storageAccounts/st-0",
        "type" => "Microsoft.Storage/storageAccounts",
        "name" => "st-0",
        "location" => "eastus",
        "properties" => %{},
        "tags" => %{},
        "systemData" => %{}
      }
    )

    other_page =
      conn(:get, rg <> "/providers/Microsoft.Storage/storageAccounts?api-version=#{seed_v}")
      |> Router.call(@opts)

    assert other_page.status == 200
    assert [%{"name" => "st-0"}] = Jason.decode!(other_page.resp_body)["value"]
  end

  # Lens-5 cycle 1 (F3b): the glob's 4th-from-end "providers" anchor is what
  # keeps malformed deep diagnosticSettings paths from becoming writes. A path
  # with an extra segment between the type and the name must 404 RouteNotFound
  # WITHOUT a store write.
  test "malformed deep diagnosticSettings path 404s without a store write" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    ds_v = Smalt.Registry.latest_version("Microsoft.Insights/diagnosticSettings")

    conn =
      conn(
        :put,
        rg <>
          "/providers/Microsoft.Insights/diagnosticSettings/extra/dsm-1?api-version=#{ds_v}",
        %{"location" => "eastus", "properties" => %{}}
      )
      |> Router.call(@opts)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"
    assert Store.list_prefix(:smalt_resources, String.downcase(rg <> "/")) == []
  end

  # Lens-5 cycle 7 (F5): the $skip/$top-style query gates — negative or
  # non-numeric $skip must fall back to the default (0), not wrap: Enum.slice
  # with a negative start would slice from the END of the list (real-ARM
  # parity: an invalid $skip is ignored, the page is still the HEAD of the
  # filtered list).
  test "negative or garbage $skip falls back to 0 — the page is still the head of the list" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    sa_v = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

    for i <- 0..2 do
      Store.put(
        :smalt_resources,
        String.downcase(rg <> "/providers/microsoft.storage/storageaccounts/st-#{i}"),
        %{
          "id" => rg <> "/providers/Microsoft.Storage/storageAccounts/st-#{i}",
          "type" => "Microsoft.Storage/storageAccounts",
          "name" => "st-#{i}",
          "location" => "eastus",
          "properties" => %{},
          "tags" => %{},
          "systemData" => %{}
        }
      )
    end

    for bad <- ["-1", "-50", "abc", "1.5", "%20-1"] do
      conn =
        conn(
          :get,
          rg <> "/providers/Microsoft.Storage/storageAccounts?api-version=#{sa_v}&$skip=#{bad}"
        )
        |> Router.call(@opts)

      assert conn.status == 200
      page = Jason.decode!(conn.resp_body)

      names = page["value"] |> Enum.map(& &1["name"])

      assert names == ["st-0", "st-1", "st-2"],
             "$skip=#{bad} did not fall back to the head of the list: #{inspect(names)}"
    end
  end

  # Lens-6 cycle 4 (F9): maxitempages is a smalt pagination extension; a
  # zero/negative/garbage value must clamp to a floor of 1 page (mirrors the
  # F5 $skip gate). Without the max(...,1) clamp a maxitempages=0 would slice
  # an EMPTY page and negative values would rely on Enum.slice's weird
  # negative-count semantics — the wire must never regress to that.
  test "zero, negative, or garbage maxitempages clamps to a 1-page floor (head of list)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    sa_v = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

    for i <- 0..2 do
      Store.put(
        :smalt_resources,
        String.downcase(rg <> "/providers/microsoft.storage/storageaccounts/st-#{i}"),
        %{
          "id" => rg <> "/providers/Microsoft.Storage/storageAccounts/st-#{i}",
          "type" => "Microsoft.Storage/storageAccounts",
          "name" => "st-#{i}",
          "location" => "eastus",
          "properties" => %{},
          "tags" => %{},
          "systemData" => %{}
        }
      )
    end

    for bad <- ["0", "-1", "abc", "1.5"] do
      conn =
        conn(
          :get,
          rg <>
            "/providers/Microsoft.Storage/storageAccounts?api-version=#{sa_v}&maxitempages=#{bad}"
        )
        |> Router.call(@opts)

      assert conn.status == 200
      page = Jason.decode!(conn.resp_body)

      names = page["value"] |> Enum.map(& &1["name"])

      assert names == ["st-0", "st-1", "st-2"],
             "maxitempages=#{bad} did not clamp to the 1-page floor: #{inspect(names)}"
    end
  end

  # Lens-5 cycle 11 (F6): the glob's 4th-from-end "providers" anchor is the
  # only thing keeping bogus-scope deep diagnosticSettings paths from becoming
  # writes — the ONLY admitted scope segment before the nested "providers" is
  # a real parent path. A path whose parent scope is not a providers segment
  # (…/providers/bogus/Microsoft.Insights/diagnosticSettings/:name) must 404
  # RouteNotFound WITHOUT a store write (kill witness for the anchor: with the
  # anchor dropped the reversed tail [name, diagnosticSettings,
  # Microsoft.Insights | _] matches and handle_child_put writes a miskeyed
  # record inside the RG prefix).
  test "bogus-scope deep diagnosticSettings path 404s without a store write (providers anchor)" do
    rg = "/subscriptions/sub-1/resourceGroups/rg-1"
    ds_v = Smalt.Registry.latest_version("Microsoft.Insights/diagnosticSettings")

    conn =
      conn(
        :put,
        rg <>
          "/providers/bogus/Microsoft.Insights/diagnosticSettings/dsm-1?api-version=#{ds_v}",
        %{"location" => "eastus", "properties" => %{}}
      )
      |> Router.call(@opts)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"
    assert Store.list_prefix(:smalt_resources, String.downcase(rg <> "/")) == []
  end

  # The router itself is stateless over public ETS; the Store GenServer is
  # started defensively so this file also runs under `mix test --no-start`
  # when the shared tree's application start is blocked by a concurrent lane.
  defp ensure_store do
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end
end
