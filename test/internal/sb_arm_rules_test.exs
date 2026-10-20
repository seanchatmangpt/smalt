# Internal-tier witness: SB rules ARM family (wave-4 SB-RULES lane).
#
# Chicago discipline: real Store rows, real ARM dispatch (Plug.Router.call
# in-process, auth :anonymous in the test env), real rules store
# (:smalt_sb_rules). No mocks.
#
#   ARM PUT topic -> 201 -> ARM PUT subscription -> 201
#   ARM PUT rule  -> 201 -> GET 200 echo -> LIST contains rule
#   LIST on a ruleless subscription synthesizes $Default true-filter
#   ARM DELETE -> 200 -> GET 404
#   PUT rule with unsupported SQL -> 400 InvalidFilter (fail-closed)
#
# Context: solo (internal tier, in-process dispatch).

defmodule InternalTier.SbArmRulesTest do
  use ExUnit.Case, async: false

  alias Smalt.Store

  @created 201
  @ok 200
  @bad_request 400
  @not_found 404

  @api_version "2021-04-01"
  @rg "/subscriptions/sub-w4e/resourceGroups/rg-w4e"
  @ns "ns-w4e"
  @topic "topic-w4e"
  @sub "sub-w4e"
  @rule "rule-w4e"

  @base "#{@rg}/providers/Microsoft.ServiceBus/namespaces/#{@ns}"

  setup do
    # Namespace parent row (providers/-prefixed key, generic ARM convention).
    ns_key = String.downcase("#{@base}")

    Store.put(:smalt_resources, ns_key, %{
      "id" => @base,
      "name" => @ns,
      "type" => "Microsoft.ServiceBus/namespaces",
      "properties" => %{}
    })

    on_exit(fn ->
      Store.delete(:smalt_sb_rules, String.downcase(rules_key("rule-w4e")))
      Store.delete(:smalt_sb_rules, String.downcase(rules_key("bad-rule")))
    end)

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
    do: arm_req(:put, "#{rules_key(name)}", %{"properties" => props})

  # -- happy path ---------------------------------------------------------------

  test "PUT topic -> PUT subscription -> PUT rule 201 -> GET 200 echo -> LIST -> DELETE -> 404" do
    # ARM topic PUT (201 create, 200 on idempotent re-put — assert create).
    topic_conn =
      arm_req(:put, "#{@base}/topics/#{@topic}", %{"location" => "eastus", "properties" => %{}})

    assert topic_conn.status == @created

    sub_conn =
      arm_req(:put, "#{@base}/topics/#{@topic}/subscriptions/#{@sub}", %{
        "location" => "eastus",
        "properties" => %{}
      })

    assert sub_conn.status == @created

    rule_conn =
      put_rule(@rule, %{
        "filter" => %{"sqlExpression" => "priority = 1"},
        "action" => %{"sqlExpression" => "SET priority = 2"}
      })

    assert rule_conn.status == @created

    rule = Jason.decode!(rule_conn.resp_body)

    # Key-level shape asserts (census: no whole-map equality).
    assert rule["name"] == @rule
    assert rule["type"] == "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"
    assert rule["id"] == "#{@base}/topics/#{@topic}/subscriptions/#{@sub}/rules/#{@rule}"
    assert rule["properties"]["filter"]["sqlExpression"] == "priority = 1"
    assert rule["properties"]["action"]["sqlExpression"] == "SET priority = 2"

    get_conn = arm_req(:get, rules_key(@rule))
    assert get_conn.status == @ok

    echoed = Jason.decode!(get_conn.resp_body)
    assert echoed["name"] == @rule
    assert echoed["properties"]["filter"]["sqlExpression"] == "priority = 1"

    list_conn = arm_req(:get, "#{@base}/topics/#{@topic}/subscriptions/#{@sub}/rules")
    assert list_conn.status == @ok

    %{"value" => rules} = Jason.decode!(list_conn.resp_body)
    rule_names = Enum.map(rules, & &1["name"])
    assert @rule in rule_names

    del_conn = arm_req(:delete, rules_key(@rule))
    assert del_conn.status == @ok

    get_conn2 = arm_req(:get, rules_key(@rule))
    assert get_conn2.status == @not_found
  end

  # -- $Default synthesis on ruleless subscription --------------------------------

  test "LIST on a subscription with no user rules synthesizes the $Default true-filter rule" do
    assert arm_req(:put, "#{@base}/topics/#{@topic}", %{"location" => "eastus", "properties" => %{}}).status == @created

    # A second subscription that never gets a user rule.
    bare = "#{@sub}-bare"

    assert arm_req(:put, "#{@base}/topics/#{@topic}/subscriptions/#{bare}", %{
             "location" => "eastus",
             "properties" => %{}
           }).status == @created

    list_conn = arm_req(:get, "#{@base}/topics/#{@topic}/subscriptions/#{bare}/rules")
    assert list_conn.status == @ok

    %{"value" => rules} = Jason.decode!(list_conn.resp_body)
    assert Enum.map(rules, & &1["name"]) == ["$Default"]
    assert hd(rules)["properties"]["trueFilter"] == true

    # A subscription WITH a user rule does not synthesize $Default.
    assert put_rule(@rule, %{"filter" => %{"sqlExpression" => "sys.label = 'w4e'"}}).status ==
             @created

    %{"value" => rules2} =
      list_conn2 = arm_req(:get, "#{@base}/topics/#{@topic}/subscriptions/#{@sub}/rules")

    assert list_conn2.status == @ok
    refute "$Default" in Enum.map(rules2, & &1["name"])
  end

  # -- typed validation ------------------------------------------------------------

  test "PUT rule with unsupported SQL filter construct refuses 400 InvalidFilter" do
    assert arm_req(:put, "#{@base}/topics/#{@topic}", %{"location" => "eastus", "properties" => %{}}).status == @created

    assert arm_req(:put, "#{@base}/topics/#{@topic}/subscriptions/#{@sub}", %{
             "location" => "eastus",
             "properties" => %{}
           }).status == @created

    conn = put_rule("bad-rule", %{"filter" => %{"sqlExpression" => "priority LIKE 'high'"}})
    assert conn.status == @bad_request

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "InvalidFilter"

    # Nothing stored for the refused rule.
    assert arm_req(:get, rules_key("bad-rule")).status == @not_found
  end
end
