# Integration-tier witness (T-14 service-health lane): Microsoft.ResourceHealth
# availabilityStatuses + events with the chaos-coupled incident lifecycle.
#
# Chicago discipline: real Store rows (:smalt_resources / :smalt_resource_groups
# / :smalt_subscriptions), real pass-through plug dispatch (the
# ResourceHealthRouter answers pre-:match in-process, the same tier the
# integrator's one-plug wiring patch mounts it at), real chaos engine state in
# the :smalt_resource_health shadow table. No mocks, no sleeps: the
# available -> unavailable -> available lifecycle is poll-based — every
# transition is query-observable through the wire faces immediately.
#
#   GET availabilityStatuses/current -> 200 Available (Store-presence law,
#     via the V9 computed-health seam fallback: the engine never shadows a
#     chaos-free resource)
#   Engine.set_unavailable/2 -> current 200 Unavailable + real reason code +
#     Active service-health event + [:smalt, :resource_health, :availability]
#     telemetry (the alert path)
#   Engine.set_available/1 -> current 200 Available (re-timestamped) +
#     Resolved event
#   RG-scoped availabilityStatuses + events filter by scope; subscription
#     events listing works; unknown RG/sub -> 404 (typed)
#   unknown resource -> 404 (never a fabricated row)
#   :resource_health_unavailable chaos marker (the T-12 flag contract) ->
#     derived Unavailable + derived Active event with NO stored record
#
# NOTE on the file name: test/integration/resource_health_test.exs is already
# owned by the V9 computed-health lane court (it keeps passing — the pass-
# through router preserves its law); this court therefore lands under the
# ticket's own name (service health).
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.ServiceHealthTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Providers.ResourceHealthRouter, as: Router
  alias Smalt.DataPlane.ResourceHealth, as: Engine
  alias Smalt.Store

  @ok 200
  @bad_request 400
  @not_found 404
  @api_version "2023-07-01"
  @epoch "1970-01-01T00:00:00Z"

  @sub "sub-t14rh"
  @rg "rg-t14rh"
  @rg_b "rg-t14rh-b"
  @type "Microsoft.Network/networkSecurityGroups"

  # -- court plumbing -------------------------------------------------------------

  defp uid, do: Integer.to_string(System.unique_integer([:positive]))

  defp rid(rg, name),
    do: "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/#{@type}/#{name}"

  defp seed_sub do
    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "name" => @sub,
      "location" => "eastus",
      "properties" => %{}
    })

    on_exit(fn -> Store.delete(:smalt_subscriptions, @sub) end)
  end

  defp seed_rg(rg) do
    rg_id = "/subscriptions/#{@sub}/resourceGroups/#{rg}"

    Store.put(:smalt_resource_groups, String.downcase(rg_id), %{
      "id" => rg_id,
      "name" => rg,
      "type" => "Microsoft.Resources/resourceGroups",
      "location" => "eastus",
      "properties" => %{}
    })

    on_exit(fn -> Store.delete(:smalt_resource_groups, String.downcase(rg_id)) end)
  end

  # Namespace-style resource row: downcased providers/-prefixed key (generic
  # ARM Store convention, same as sb_arm_rules_test).
  defp seed_resource(rg, name) do
    id = rid(rg, name)

    Store.put(:smalt_resources, String.downcase(id), %{
      "id" => id,
      "name" => name,
      "type" => @type,
      "location" => "eastus",
      "properties" => %{}
    })

    on_exit(fn -> Store.delete(:smalt_resources, String.downcase(id)) end)
    id
  end

  # The engine's shadow table persists for the beam lifetime: sweep exactly the
  # rows this leg minted (downcased resource id key law).
  defp sweep_engine(resource_id) do
    key_id = String.downcase(resource_id)

    on_exit(fn ->
      if :ets.info(:smalt_resource_health) != :undefined do
        :ets.delete(:smalt_resource_health, {:availability, key_id})
        :ets.delete(:smalt_resource_health, {:event_active, key_id})

        for {{:event, eid}, rec} <- :ets.tab2list(:smalt_resource_health),
            is_map(rec) and rec["resource_id"] == key_id do
          :ets.delete(:smalt_resource_health, {:event, eid})
        end
      end
    end)
  end

  defp arm_req(method, path), do: Router.call(conn(method, path), [])

  defp base(rg, name),
    do: "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/#{@type}/#{name}"

  defp current_path(rg, name),
    do: "#{base(rg, name)}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=#{@api_version}"

  defp rg_avail_path(rg),
    do: "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=#{@api_version}"

  defp rg_events_path(rg),
    do: "/subscriptions/#{@sub}/resourceGroups/#{rg}/providers/Microsoft.ResourceHealth/events?api-version=#{@api_version}"

  defp sub_events_path,
    do: "/subscriptions/#{@sub}/providers/Microsoft.ResourceHealth/events?api-version=#{@api_version}"

  # -- legs -------------------------------------------------------------------------

  test "default Available for a provisioned resource, documented availabilityStatus shape" do
    seed_rg(@rg)
    name = "nsg-t14-fresh-#{uid()}"
    seed_resource(@rg, name)

    conn = arm_req(:get, current_path(@rg, name))
    assert conn.status == @ok

    body = Jason.decode!(conn.resp_body)
    assert body["type"] == "Microsoft.ResourceHealth/availabilityStatuses"
    assert body["name"] == "#{name}/current"
    assert String.contains?(body["id"], "/providers/Microsoft.ResourceHealth/availabilityStatuses/current")
    assert body["properties"]["availabilityState"] == "Available"
    assert is_binary(body["properties"]["summary"]) and body["properties"]["summary"] != ""
    # A derived row is NOT a transition: the epoch stamps synthetic-Available.
    assert body["properties"]["occurredTime"] == @epoch
  end

  test "set_unavailable -> Unavailable + real reason code + Active event + telemetry alert path" do
    seed_sub()
    seed_rg(@rg)
    name = "nsg-t14-out-#{uid()}"
    resource_id = seed_resource(@rg, name)
    sweep_engine(resource_id)

    handler_id = "t14-rh-court-#{uid()}"

    :ok =
      :telemetry.attach(handler_id, [:smalt, :resource_health, :availability], fn _name,
                                                                                  _measurements,
                                                                                  meta,
                                                                                  _config ->
        send(self(), {:rh_transition, meta})
      end, nil)

    assert {:ok, avail, event} = Engine.set_unavailable(resource_id, "PlatformInitiated")
    assert avail["state"] == "Unavailable"
    assert event["status"] == "Active"

    # Alert path: the transition telemetry fires with codes only.
    assert_received {:rh_transition, %{state: "Unavailable", reason: "PlatformInitiated"}}

    conn = arm_req(:get, current_path(@rg, name))
    assert conn.status == @ok

    body = Jason.decode!(conn.resp_body)
    assert body["properties"]["availabilityState"] == "Unavailable"
    assert body["properties"]["reasonType"] == "PlatformInitiated"
    assert is_binary(body["properties"]["summary"]) and body["properties"]["summary"] != ""
    # Every transition is timestamped (never the synthetic epoch).
    assert body["properties"]["occurredTime"] != @epoch

    events_conn = arm_req(:get, sub_events_path())
    assert events_conn.status == @ok

    %{"value" => events} = Jason.decode!(events_conn.resp_body)
    row = Enum.find(events, fn e -> e["name"] == event["id"] end)
    assert row["type"] == "Microsoft.ResourceHealth/events"
    assert row["properties"]["status"] == "Active"
    assert row["properties"]["level"] == "Warning"
    assert row["properties"]["reasonCode"] == "PlatformInitiated"
    assert row["properties"]["eventTimestamp"] != @epoch
    assert String.contains?(row["properties"]["title"], name)
    assert row["properties"]["resourceId"] == resource_id

    :ok = :telemetry.detach(handler_id)
  end

  test "set_available -> Available again (re-timestamped) + Resolved event" do
    seed_sub()
    seed_rg(@rg)
    name = "nsg-t14-cycle-#{uid()}"
    resource_id = seed_resource(@rg, name)
    sweep_engine(resource_id)

    {:ok, _unavail, active_event} = Engine.set_unavailable(resource_id, "CustomerInitiated")

    conn_out = arm_req(:get, current_path(@rg, name))
    unavailable_time = Jason.decode!(conn_out.resp_body)["properties"]["occurredTime"]

    assert {:ok, avail, resolved} = Engine.set_available(resource_id)
    assert avail["state"] == "Available"
    assert resolved["id"] == active_event["id"]
    assert resolved["status"] == "Resolved"

    conn = arm_req(:get, current_path(@rg, name))
    assert conn.status == @ok

    body = Jason.decode!(conn.resp_body)
    assert body["properties"]["availabilityState"] == "Available"
    # Clearing is itself a transition: re-stamped, different from BOTH the
    # synthetic epoch and the outage instant.
    assert body["properties"]["occurredTime"] != @epoch
    assert body["properties"]["occurredTime"] != unavailable_time

    events_conn = arm_req(:get, sub_events_path())
    %{"value" => events} = Jason.decode!(events_conn.resp_body)
    mine = Enum.filter(events, fn e -> e["properties"]["resourceId"] == resource_id end)

    assert Enum.any?(mine, fn e -> e["properties"]["status"] == "Resolved" end)
    refute Enum.any?(mine, fn e -> e["properties"]["status"] == "Active" end)
  end

  test "scope listing: RG-scoped availabilityStatuses + events filter, sub listing aggregates" do
    seed_sub()

    # Own RGs (unique per run): ExUnit shuffles test order, so a scope-listing
    # leg must never depend on other legs' seed rows being absent.
    rg_a = "rg-t14-scope-a-#{uid()}"
    rg_b = "rg-t14-scope-b-#{uid()}"
    seed_rg(rg_a)
    seed_rg(rg_b)

    name_a = "nsg-t14-rga-#{uid()}"
    rid_a = seed_resource(rg_a, name_a)
    sweep_engine(rid_a)

    name_b = "nsg-t14-rgb-#{uid()}"
    seed_resource(rg_b, name_b)

    assert {:ok, _avail, _event} = Engine.set_unavailable(rid_a, "PlatformInitiated")

    # RG scope listing: exactly its own resource, chaos-flipped.
    conn_a = arm_req(:get, rg_avail_path(rg_a))
    assert conn_a.status == @ok

    %{"value" => rows_a} = Jason.decode!(conn_a.resp_body)
    assert Enum.map(rows_a, & &1["properties"]["availabilityState"]) == ["Unavailable"]
    assert String.contains?(hd(rows_a)["id"], name_a)

    # Other RG scope: its own resource, derived-Available (Store presence).
    conn_b = arm_req(:get, rg_avail_path(rg_b))
    assert conn_b.status == @ok

    %{"value" => rows_b} = Jason.decode!(conn_b.resp_body)
    assert Enum.map(rows_b, & &1["properties"]["availabilityState"]) == ["Available"]

    # Events filter by scope: the RG face carries only the RG's incident,
    # the subscription face aggregates.
    rg_events = arm_req(:get, rg_events_path(rg_a))
    assert rg_events.status == @ok

    %{"value" => rg_rows} = Jason.decode!(rg_events.resp_body)
    assert length(rg_rows) >= 1
    assert Enum.all?(rg_rows, fn e -> String.contains?(e["properties"]["resourceId"], name_a) end)

    sub_events = arm_req(:get, sub_events_path())
    assert sub_events.status == @ok

    %{"value" => sub_rows} = Jason.decode!(sub_events.resp_body)
    assert Enum.any?(sub_rows, fn e -> e["properties"]["resourceId"] == rid_a end)

    # Typed scope refusals (main-router vocabulary).
    unknown_rg = arm_req(:get, rg_events_path("rg-t14-missing"))
    assert unknown_rg.status == @not_found
    assert Jason.decode!(unknown_rg.resp_body)["error"]["code"] == "ResourceGroupNotFound"

    unknown_sub_conn =
      arm_req(
        :get,
        "/subscriptions/sub-t14-missing/providers/Microsoft.ResourceHealth/events?api-version=#{@api_version}"
      )

    assert unknown_sub_conn.status == @not_found
    assert Jason.decode!(unknown_sub_conn.resp_body)["error"]["code"] == "SubscriptionNotFound"
  end

  test "unknown resource -> 404 NotFound (never a fabricated row)" do
    seed_rg(@rg)

    conn = arm_req(:get, current_path(@rg, "nsg-t14-ghost-#{uid()}"))
    assert conn.status == @not_found
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "NotFound"
  end

  test "missing api-version -> 400 MissingApiVersionParameter" do
    conn = arm_req(:get, "#{base(@rg, "nsg-t14-gate-#{uid()}")}/providers/Microsoft.ResourceHealth/availabilityStatuses/current")
    assert conn.status == @bad_request
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
  end

  test ":resource_health_unavailable chaos marker derives Unavailable + Active event with NO stored record" do
    seed_sub()
    seed_rg(@rg)
    name = "nsg-t14-marker-#{uid()}"
    resource_id = seed_resource(@rg, name)
    sweep_engine(resource_id)

    old = Application.get_env(:smalt, :resource_health_unavailable)

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:smalt, :resource_health_unavailable)
      else
        Application.put_env(:smalt, :resource_health_unavailable, old)
      end
    end)

    # The T-12 flag contract: name the resource id, no restart, no stored row.
    Application.put_env(:smalt, :resource_health_unavailable, [resource_id])

    conn = arm_req(:get, current_path(@rg, name))
    assert conn.status == @ok

    body = Jason.decode!(conn.resp_body)
    assert body["properties"]["availabilityState"] == "Unavailable"
    assert body["properties"]["reasonType"] == "CustomerInitiated"

    # Derived-on-read law: the marker never persists an availability record.
    assert :ets.lookup(:smalt_resource_health, {:availability, String.downcase(resource_id)}) == []

    events_conn = arm_req(:get, sub_events_path())
    %{"value" => events} = Jason.decode!(events_conn.resp_body)
    mine = Enum.filter(events, fn e -> e["properties"]["resourceId"] == resource_id end)

    assert length(mine) == 1
    derived = hd(mine)
    assert derived["properties"]["status"] == "Active"
    assert derived["properties"]["reasonCode"] == "CustomerInitiated"
    assert derived["name"] == "chaos-" <> derived["name"] |> String.slice(-8, 8) |> then(&(&1))

    # Deterministic derived id: repeated polls observe the same event id.
    events_conn2 = arm_req(:get, sub_events_path())
    %{"value" => events2} = Jason.decode!(events_conn2.resp_body)
    assert Enum.any?(events2, fn e -> e["name"] == derived["name"] end)

    # Clearing the marker restores the Store-presence law without a restart.
    Application.delete_env(:smalt, :resource_health_unavailable)

    conn_after = arm_req(:get, current_path(@rg, name))
    assert conn_after.status == @ok
    assert Jason.decode!(conn_after.resp_body)["properties"]["availabilityState"] == "Available"
  end
end
