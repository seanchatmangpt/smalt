# KD-143 court (integration tier, in-process ARM dispatch): SQL-filter rule
# persistence + evaluation across the Azure-typed rule body shape.
#
# Chicago discipline: real Store rows (:smalt_resources / :smalt_sb_rules),
# real ARM dispatch (Plug.Router.call, auth :anonymous in test env). No mocks.
#
#   PUT rule {properties:{filterType:"SqlFilter", sqlFilter:{sqlExpression:…}}}
#     -> 201, GET echoes sqlFilter.sqlExpression (KD-143 defect: trueFilter echo)
#   subscription_admits? admits a matching message, skips a non-matching one
#   Legacy nested `filter` shape still round-trips (no regression).
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.Kd143RulesPersistenceTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Store

  @created 201
  @ok 200
  @bad_request 400
  @not_found 404

  @api_version "2021-04-01"
  @rg "/subscriptions/sub-kd143/resourceGroups/rg-kd143"
  @ns "ns-kd143"
  @topic "topic-kd143"
  @sub "sub-kd143"

  @base "#{@rg}/providers/Microsoft.ServiceBus/namespaces/#{@ns}"

  setup do
    ns_key = String.downcase(@base)

    Store.put(:smalt_resources, ns_key, %{
      "id" => @base,
      "name" => @ns,
      "type" => "Microsoft.ServiceBus/namespaces",
      "properties" => %{}
    })

    :ok
  end

  defp rules_key(rule),
    do: "#{@base}/topics/#{@topic}/subscriptions/#{@sub}/rules/#{rule}"

  defp arm_req(method, path, body \\ nil) do
    url = "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp put_rule(name, props),
    do: arm_req(:put, rules_key(name), %{"properties" => props})

  defp ensure_topic_sub do
    assert arm_req(:put, "#{@base}/topics/#{@topic}", %{
             "location" => "eastus",
             "properties" => %{}
           }).status in [@created, @ok]

    assert arm_req(:put, "#{@base}/topics/#{@topic}/subscriptions/#{@sub}", %{
             "location" => "eastus",
             "properties" => %{}
           }).status in [@created, @ok]
  end

  # -- KD-143: typed sqlFilter shape persists and echoes ---------------------------

  test "PUT rule with sqlFilter.sqlExpression -> 201, GET echoes sqlFilter.sqlExpression" do
    ensure_topic_sub()

    conn =
      put_rule("kd143-sql", %{
        "filterType" => "SqlFilter",
        "sqlFilter" => %{"sqlExpression" => "priority = 'high'"}
      })

    assert conn.status == @created
    created = Jason.decode!(conn.resp_body)
    assert created["properties"]["sqlFilter"]["sqlExpression"] == "priority = 'high'"

    get_conn = arm_req(:get, rules_key("kd143-sql"))
    assert get_conn.status == @ok

    echoed = Jason.decode!(get_conn.resp_body)
    assert echoed["name"] == "kd143-sql"
    assert echoed["properties"]["sqlFilter"]["sqlExpression"] == "priority = 'high'"
    assert echoed["properties"]["filter"]["sqlExpression"] == "priority = 'high'"
  end

  test "stored sqlFilter drives subscription_admits? (match admits, non-match skips)" do
    ensure_topic_sub()

    # Global ETS persists across tests: drop any rules leaked by sibling
    # tests on this shared subscription BEFORE putting the rule under test.
    pre =
      String.downcase(
        "#{@rg}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules/"
      )

    Enum.each(Store.list_prefix(:smalt_sb_rules, pre), fn r ->
      Store.delete(:smalt_sb_rules, String.downcase(r["id"]))
    end)

    assert put_rule("kd143-sql2", %{
             "filterType" => "SqlFilter",
             "sqlFilter" => %{"sqlExpression" => "priority = 'high'"}
           }).status == @created

    prefix =
      String.downcase(
        "#{@rg}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules/"
      )

    rules = Store.list_prefix(:smalt_sb_rules, prefix)
    assert length(rules) >= 1

    matching = %{app_props: %{"priority" => "high"}, body: "m"}
    non_matching = %{app_props: %{"priority" => "low"}, body: "m"}

    assert Smalt.SbRules.subscription_admits?(rules, matching)
    refute Smalt.SbRules.subscription_admits?(rules, non_matching)
  end

  test "PUT rule with invalid sqlFilter SQL refuses 400 InvalidFilter (fail-closed)" do
    ensure_topic_sub()

    conn =
      put_rule("kd143-bad", %{
        "filterType" => "SqlFilter",
        "sqlFilter" => %{"sqlExpression" => "priority LIKE 'high'"}
      })

    assert conn.status == @bad_request
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidFilter"
    assert arm_req(:get, rules_key("kd143-bad")).status == @not_found
  end

  test "correlationFilter shape normalizes and echoes" do
    ensure_topic_sub()

    conn =
      put_rule("kd143-corr", %{
        "filterType" => "CorrelationFilter",
        "correlationFilter" => %{"correlationId" => "cid-9", "subject" => "alerts"}
      })

    assert conn.status == @created

    echoed = Jason.decode!(arm_req(:get, rules_key("kd143-corr")).resp_body)
    assert echoed["properties"]["correlationFilter"]["correlationId"] == "cid-9"
    assert echoed["properties"]["filter"]["correlationId"] == "cid-9"
  end

  # -- legacy shape regression ------------------------------------------------------

  test "legacy nested filter shape still round-trips (regression guard)" do
    ensure_topic_sub()

    conn =
      put_rule("kd143-legacy", %{
        "filter" => %{"sqlExpression" => "color = 'red'"},
        "action" => %{"sqlExpression" => "SET color = 'blue'"}
      })

    assert conn.status == @created

    echoed = Jason.decode!(arm_req(:get, rules_key("kd143-legacy")).resp_body)
    assert echoed["properties"]["filter"]["sqlExpression"] == "color = 'red'"
    assert echoed["properties"]["sqlFilter"]["sqlExpression"] == "color = 'red'"
    assert echoed["properties"]["action"]["sqlExpression"] == "SET color = 'blue'"
  end

  test "empty/absent filter body still persists a trueFilter rule" do
    ensure_topic_sub()

    conn = put_rule("kd143-true", %{})
    assert conn.status == @created

    echoed = Jason.decode!(arm_req(:get, rules_key("kd143-true")).resp_body)
    assert echoed["properties"]["filter"]["trueFilter"] == true
    assert echoed["properties"]["filterType"] == "TrueFilter"
  end
end
