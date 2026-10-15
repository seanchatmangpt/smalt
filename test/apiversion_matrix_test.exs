defmodule ApiVersionMatrixTest do
  @moduledoc """
  api-version validation fence, table-driven over the real route inventory.

  For every admitted resource type that has a PUT route in
  `Smalt.ArmGateway.Router` (top-level types via the generic provider route,
  child types via their dedicated child routes):

    1. PUT with `Registry.latest_version(type)` -> api-version VALIDATION
       passes (any status except a 400 ARM envelope whose code is
       InvalidApiVersionParameter / MissingApiVersionParameter; 201/202/
       400-shape/404-parent are all acceptable outcomes downstream).
    2. PUT with api-version "1999-01-01"        -> 400 InvalidApiVersionParameter.
    3. PUT without api-version                  -> 400 MissingApiVersionParameter.

  Plus two inventory rows:

  - registry completeness: every resource-type string literal in the router's
    route inventory appears in `Registry.admitted_resource_types/0`.
  - route gaps: admitted child-path types whose child path has NOT landed as a
    router route (multi-segment leaf types other than the five with dedicated
    routes) are asserted to currently return 404 RouteNotFound — the generic
    PUT route matches only one resource-type segment. When a dedicated child
    route lands, move the type into @child_routes and join the three-PUT fence.

  Each row cites the router file:line of the PUT route it exercises.
  """

  use ExUnit.Case
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "matrix-rg"

  # router.ex:794 — generic provider PUT route
  @generic_put_line "lib/smalt/arm_gateway/router.ex:954"

  setup do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    ensure_parents()

    :ok
  end

  # Parented SB/EH child PUTs 404 when the parent is absent (router
  # handle_parented_child/6), which would mask the api-version fence — create
  # the parent chain up front via the real router.
  defp ensure_parents do
    # Parents created in dependency order through the real router. Payloads
    # satisfy the GraphLaw shapes (priv/shacl/smalt-shapes.ttl): SB namespaces
    # need properties.skuName; EH hub needs nothing beyond location.
    create("Microsoft.ServiceBus/namespaces", "providers/Microsoft.ServiceBus/namespaces/matrix-ns",
           %{"location" => "eastus", "properties" => %{"skuName" => "Standard"}})

    # Topic and hub are themselves UNADMITTED (the defect under test), so a
    # router PUT refuses with InvalidResourceShape and the nested parent never
    # exists. Seed the topic/hub records directly under the exact key
    # handle_child_put/5 derives, so the child fence rows hit the real route.
    Store.put(
      :smalt_resources,
      String.downcase("/subscriptions/#{@sub}/resourceGroups/#{@rg}/namespaces/matrix-ns/topics/matrix-topic"),
      %{"id" => "seeded", "type" => "Microsoft.ServiceBus/namespaces/topics", "properties" => %{}}
    )

    Store.put(
      :smalt_resources,
      String.downcase("/subscriptions/#{@sub}/resourceGroups/#{@rg}/namespaces/matrix-ehns/eventhubs/matrix-hub"),
      %{"id" => "seeded", "type" => "Microsoft.EventHub/namespaces/eventhubs", "properties" => %{}}
    )

    create("Microsoft.EventHub/namespaces", "providers/Microsoft.EventHub/namespaces/matrix-ehns",
           %{"location" => "eastus", "properties" => %{}})

    create("Microsoft.EventHub/namespaces/eventhubs",
           "providers/Microsoft.EventHub/namespaces/matrix-ehns/eventhubs/matrix-hub",
           %{"location" => "eastus", "properties" => %{}})
  end

  defp create(parent_type, path, payload) do
    result = put_resource(parent_type, path, Registry.latest_version(parent_type) || "2021-04-01", payload)
    result
    # Parents that are themselves unadmitted in Registry validate no
    # api-version (router check_version/3 returns :ok when find_admitted/1 is
    # nil); a placeholder version then works for parent creation.
    put_resource(parent_type, path, Registry.latest_version(parent_type) || "2021-04-01", payload)
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> ensure_store()
          end
        end
    end
  end

  # ===========================================================================
  # Route inventory (each row cites its PUT route in the router)
  # ===========================================================================

  # Child-path types with DEDICATED PUT routes in router.ex (grep of
  # handle_child_put call sites; each row cites the route's file:line).
  @child_routes [
    {"Microsoft.Network/subnets", "providers/Microsoft.Network/virtualNetworks/matrix-vnet/subnets/matrix-subnet",
     "lib/smalt/arm_gateway/router.ex:754"},
    {"Microsoft.KeyVault/vaults/keys", "providers/Microsoft.KeyVault/vaults/matrix-vault/keys/matrix-key",
     "lib/smalt/arm_gateway/router.ex:771"},
    {"Microsoft.Storage/storageAccounts/blobServices",
     "providers/Microsoft.Storage/storageAccounts/matrix-acct/blobServices/default",
     "lib/smalt/arm_gateway/router.ex:788"},
    {"Microsoft.Storage/storageAccounts/blobServices/containers",
     "providers/Microsoft.Storage/storageAccounts/matrix-acct/blobServices/default/containers/matrix-container",
     "lib/smalt/arm_gateway/router.ex:801"},
    {"Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
     "providers/Microsoft.Storage/storageAccounts/matrix-acct/blobServices/default/containers/matrix-container/immutabilityPolicies/matrix-policy",
     "lib/smalt/arm_gateway/router.ex:818"}
  ]

  # SB/EH messaging children: LANDED in router.ex (handle_parented_child PUT
  # routes, router.ex:858/875/892/909/926) but NOT admitted in Registry — the
  # api-version fence below pins the expected 400 InvalidApiVersionParameter
  # for them too; rows go red until Registry admits the type.
  @parented_routes [
    {"Microsoft.ServiceBus/namespaces/queues",
     {"Microsoft.ServiceBus/namespaces", "matrix-ns"},
     "providers/Microsoft.ServiceBus/namespaces/matrix-ns/queues/matrix-queue",
     "lib/smalt/arm_gateway/router.ex:858"},
    {"Microsoft.ServiceBus/namespaces/topics",
     {"Microsoft.ServiceBus/namespaces", "matrix-ns"},
     "providers/Microsoft.ServiceBus/namespaces/matrix-ns/topics/matrix-topic",
     "lib/smalt/arm_gateway/router.ex:875"},
    {"Microsoft.ServiceBus/namespaces/topics/subscriptions",
     {"Microsoft.ServiceBus/namespaces/topics", "matrix-topic"},
     "providers/Microsoft.ServiceBus/namespaces/matrix-ns/topics/matrix-topic/subscriptions/matrix-sub",
     "lib/smalt/arm_gateway/router.ex:892"},
    {"Microsoft.EventHub/namespaces/eventhubs",
     {"Microsoft.EventHub/namespaces", "matrix-ehns"},
     "providers/Microsoft.EventHub/namespaces/matrix-ehns/eventhubs/matrix-hub",
     "lib/smalt/arm_gateway/router.ex:909"},
    {"Microsoft.EventHub/namespaces/eventhubs/consumergroups",
     {"Microsoft.EventHub/namespaces/eventhubs", "matrix-hub"},
     "providers/Microsoft.EventHub/namespaces/matrix-ehns/eventhubs/matrix-hub/consumergroups/matrix-cg",
     "lib/smalt/arm_gateway/router.ex:926"}
  ]

  @child_types MapSet.new(Enum.map(@child_routes, fn {t, _, _} -> t end))

  # Types with a landed PUT route but no dedicated child route ride the generic
  # provider PUT route (router.ex:794): single-segment resource types only —
  # that route matches exactly :provider_ns/:resource_type/:resource_name.
  @generic_rows (
    Registry.admitted_resource_types()
    |> Enum.reject(&MapSet.member?(@child_types, &1))
    |> Enum.sort()
    |> Enum.flat_map(fn type ->
      case String.split(type, "/", parts: 2) do
        [ns, leaf] ->
          if leaf != "" and not String.contains?(leaf, "/") do
            [{type, "providers/#{ns}/#{leaf}/matrix-res", @generic_put_line}]
          else
            []
          end

        _ ->
          []
      end
    end)
  )

  @matrix_rows @child_routes ++ @generic_rows

  # Parented rows for the fence loop: {type, path, cite}
  @parented_routes_as_rows Enum.map(@parented_routes, fn {t, _, path, cite} -> {t, path, cite} end)

  # Admitted child-path types whose child route has NOT landed.
  @gap_types (
    Registry.admitted_resource_types()
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(Enum.map(@matrix_rows, fn {t, _, _} -> t end)))
    |> MapSet.to_list()
    |> Enum.sort()
  )

  test "route inventory rows cover every single-segment admitted type" do
    deep_single_segment =
      Enum.filter(Registry.admitted_resource_types(), fn t -> t in @gap_types end)
      |> Enum.reject(fn t ->
        [_ns, leaf] = String.split(t, "/", parts: 2)
        String.contains?(leaf, "/")
      end)

    assert deep_single_segment == [],
           "single-segment admitted types missing from the matrix: #{inspect(deep_single_segment)}"
  end

  test "every admitted type is in exactly one matrix class (fence row or gap row)" do
    fenced = MapSet.new(Enum.map(@matrix_rows, fn {t, _, _} -> t end))
    gaps = MapSet.new(@gap_types)

    assert MapSet.size(fenced) + MapSet.size(gaps) == length(Registry.admitted_resource_types())
    assert MapSet.size(MapSet.intersection(fenced, gaps)) == 0
  end

  # ===========================================================================
  # The fence: three PUTs per route row
  # ===========================================================================

  for {type, child_path, cite} <- @matrix_rows ++ @parented_routes_as_rows do
    describe "#{type} (#{cite})" do
      test "PUT with latest api-version passes api-version VALIDATION" do
        # Unadmitted types validate no api-version (check_version/3 :ok when
        # find_admitted/1 is nil), so any placeholder passes validation; when
        # Registry admits the type the real latest version is used.
        version = Registry.latest_version(unquote(type)) || "2021-04-01"
        conn = put_resource(unquote(type), unquote(child_path), version)

        # The fence: api-version validation passed. Downstream outcomes may be
        # 200/201 (created), 202 (LRO), 400 (GraphLaw shape refusal) or
        # 404-parent — but never an api-version rejection.
        refute api_version_error?(conn),
               "expected api-version #{version} to pass validation but got " <>
                 inspect(%{status: conn.status, code: error_code(conn), body: conn.resp_body})

        assert conn.status in [200, 201, 202, 400, 404]
      end

      test "PUT with api-version 1999-01-01 -> 400 InvalidApiVersionParameter" do
        conn = put_resource(unquote(type), unquote(child_path), "1999-01-01")

        assert conn.status == 400
        assert error_code(conn) == "InvalidApiVersionParameter"
      end

      test "PUT without api-version -> 400 MissingApiVersionParameter" do
        conn = put_resource(unquote(type), unquote(child_path), :omit)

        assert conn.status == 400
        assert error_code(conn) == "MissingApiVersionParameter"
      end
    end
  end

  # ===========================================================================
  # Route-gap rows: child-path types whose child route has NOT landed
  # ===========================================================================

  describe "route gaps (child routes not yet landed)" do
    test "deep child-path types currently return 404 RouteNotFound on PUT" do
      for type <- @gap_types do
        conn = put_resource(type, generic_deep_path(type), "1999-01-01")

        assert {conn.status, error_code(conn)} == {404, "RouteNotFound"},
               "expected 404 RouteNotFound for un-routed child-path type #{type} but got " <>
                 inspect(%{status: conn.status, code: error_code(conn)}) <>
                 " — if a dedicated child route has landed, move this type into @child_routes"
      end
    end
  end

  # ===========================================================================
  # Registry-completeness row: router route type literals ⊆ admitted types
  # ===========================================================================

  test "every route resource-type literal in router.ex is an admitted registry type" do
    router_source = File.read!("lib/smalt/arm_gateway/router.ex")

    route_type_literals =
      Regex.scan(~r/"(Microsoft\.[A-Za-z]+(?:\/[A-Za-z]+)+)"/, router_source)
      |> Enum.map(&Enum.at(&1, 1))
      |> MapSet.new()
      # Excluded: "Microsoft.Authorization/locks" is a response-envelope type
      # literal in the azapi lock action body (router.ex:371), not a route's
      # resource-type string. It is not an admitted registry type and rides the
      # POST action route, not a PUT route.
      |> MapSet.delete("Microsoft.Authorization/locks")

    admitted = MapSet.new(Registry.admitted_resource_types())

    unadmitted = MapSet.difference(route_type_literals, admitted)
    assert MapSet.size(unadmitted) == 0,
           "router route type literals not present in Registry.admitted_resource_types/0: " <>
             inspect(MapSet.to_list(unadmitted))
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp generic_deep_path(type) do
    [ns, leaf] = String.split(type, "/", parts: 2)
    "providers/#{ns}/#{leaf}/matrix-res"
  end

  defp put_resource(_type, child_path, version, payload \\ %{"location" => "eastus", "properties" => %{}}) do
    path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}/#{child_path}"

    uri =
      case version do
        :omit -> path
        v -> path <> "?api-version=" <> v
      end

    conn =
      :put
      |> conn(uri, Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")

    call(conn)
  end

  # ===========================================================================
  # Lens-2 matrix sweep (generated): every admitted type x {matched GET-list,
  # matched DELETE, unmatched POST} x api-version — pins the precedence law
  #   matched route:    api-version 400 BEFORE any 404 (store/parent/route)
  #   unmatched route:  404 RouteNotFound BEFORE the api-version gate
  # (the catch-all RouteNotFound handler does not consult api-version —
  # pinned as the contract, mirroring real ARM's unmatched-route 404).
  # ===========================================================================

  describe "matrix sweep" do
    # GET-list row: single-segment types only — a deep type's short path
    # (e.g. providers/Microsoft.KeyVault/vaults/keys) is AMBIGUOUS on the
    # route table (matches the generic GET-resource route as vault "keys",
    # validating against Microsoft.KeyVault/vaults), and the deep types'
    # dedicated list routes are already fenced by the child-route matrix.
    for type <- Enum.sort(Registry.admitted_resource_types()), byte_size(type) - byte_size(String.replace(type, "/", "")) == 1 do
      test "sweep #{type}: matched GET-list with latest passes validation" do
        type = unquote(type)
        [ns | rest] = String.split(type, "/", parts: 2)
        path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns}/#{rest}"

        conn =
          conn(:get, path <> "?api-version=#{Registry.latest_version(type)}")
          |> Router.call(@opts)

        refute api_version_error?(conn),
               "expected latest #{Registry.latest_version(type)} to pass on GET-list, got " <>
                 inspect(%{status: conn.status, code: error_code(conn)})
      end

      test "sweep #{type}: matched DELETE with latest passes validation" do
        type = unquote(type)
        [ns | rest] = String.split(type, "/", parts: 2)
        path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns}/#{rest}/sweep-res"

        conn =
          conn(:delete, path <> "?api-version=#{Registry.latest_version(type)}")
          |> Router.call(@opts)

        refute api_version_error?(conn)
      end

      test "sweep #{type}: unmatched POST -> 404 ActionNotFound even with stale api-version" do
        type = unquote(type)
        [ns | rest] = String.split(type, "/", parts: 2)
        path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns}/#{rest}/sweep-res"

        conn =
          conn(:post, path <> "?api-version=1999-01-01")
          |> Router.call(@opts)

        assert conn.status == 404

        # The azapi action route is the catch-all POST at .../providers/*glob
        # depth, so an unknown action 404s as ActionNotFound (route MATCHES;
        # the api-version gate inside it is presence-only and 1999-01-01 is
        # present — precedence still observed: 404, never an api-version 400).
        assert error_code(conn) == "ActionNotFound"
      end
    end
  end

  defp error_code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ -> nil
    end
  end

  defp api_version_error?(conn) do
    conn.status == 400 and
      error_code(conn) in ["InvalidApiVersionParameter", "MissingApiVersionParameter"]
  end
end
