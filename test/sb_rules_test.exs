defmodule Smalt.SbRulesTest do
  @moduledoc """
  80/20 Service Bus subscription rules (SB-RULES lane).

  Wire tier: rule CRUD on
  .../namespaces/:ns/topics/:topic/subscriptions/:sub/rules[/:ruleName] over
  the real ARM router (typed 400 InvalidFilter/InvalidAction at rule-create
  time; $Default synthesized on LIST; missing parent subscription -> 404).
  Evaluator tier: real `Smalt.SbRules` over the real Store — SQL filter
  matching (app properties, sys.label, EXISTS, AND/OR, parens), correlation
  filters, SET-only actions, and `fan_out/4` delivery (matching message
  reaches exactly the sql-filter subscription; action overrides ride the
  delivered message).
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store
  alias Smalt.SbRules

  @opts Router.init([])

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    :ok
  end

  # -- Wire tier: rule CRUD ---------------------------------------------------------

  describe "rule CRUD over the ARM router" do
    @tag sb_rules: "sql-rule-lifecycle"
    test "PUT 201 -> GET carries filter, LIST shows it, DELETE -> GET 404" do
      setup_topic_sub("sbns-r1", "t1", "s1")

      put_conn = put_rule("sbns-r1", "t1", "s1", "order-only", %{
        "sqlExpression" => "ordertype = 'priority' OR sys.label = 'vip'"
      })

      assert put_conn.status == 201
      record = Jason.decode!(put_conn.resp_body)
      assert record["name"] == "order-only"
      assert record["type"] == "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"
      assert record["properties"]["filter"]["sqlExpression"] ==
               "ordertype = 'priority' OR sys.label = 'vip'"

      get_conn = rule_req(:get, "sbns-r1", "t1", "s1", "order-only")
      assert get_conn.status == 200
      assert Jason.decode!(get_conn.resp_body)["properties"]["filter"]["sqlExpression"] ==
               "ordertype = 'priority' OR sys.label = 'vip'"

      list_conn = rule_req(:get, "sbns-r1", "t1", "s1", nil)
      assert list_conn.status == 200
      names = Enum.map(Jason.decode!(list_conn.resp_body)["value"], & &1["name"])
      assert names == ["order-only"]

      del_conn = rule_req(:delete, "sbns-r1", "t1", "s1", "order-only")
      assert del_conn.status == 200

      gone = rule_req(:get, "sbns-r1", "t1", "s1", "order-only")
      assert {404, "RuleNotFound"} = {gone.status, code(gone)}
    end

    @tag sb_rules: "default-rule-synthesis"
    test "LIST on a subscription with no user rules synthesizes $Default true-filter" do
      setup_topic_sub("sbns-r2", "t1", "s1")

      list_conn = rule_req(:get, "sbns-r2", "t1", "s1", nil)
      assert list_conn.status == 200

      assert [%{"name" => "$Default"}] = Jason.decode!(list_conn.resp_body)["value"]
      default = Jason.decode!(list_conn.resp_body)["value"] |> hd()
      assert default["type"] == "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"
      assert is_map(default["properties"])
    end

    @tag sb_rules: "invalid-filter-400"
    test "unsupported SQL filter construct -> typed 400 InvalidFilter at create" do
      setup_topic_sub("sbns-r3", "t1", "s1")

      conn =
        put_rule("sbns-r3", "t1", "s1", "bad", %{"sqlExpression" => "ordertype LIKE 'p%'"})

      assert {400, "InvalidFilter"} = {conn.status, code(conn)}
      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "ordertype"

      # nothing was stored
      get_conn = rule_req(:get, "sbns-r3", "t1", "s1", "bad")
      assert get_conn.status == 404
    end

    @tag sb_rules: "invalid-action-400"
    test "unsupported action (non-SET) -> typed 400 InvalidAction at create" do
      setup_topic_sub("sbns-r4", "t1", "s1")

      conn =
        put_rule("sbns-r4", "t1", "s1", "bad-action", %{"sqlExpression" => "sys.label = 'x'"}, %{
          "sqlExpression" => "REMOVE prop1"
        })

      assert {400, "InvalidAction"} = {conn.status, code(conn)}
    end

    @tag sb_rules: "rule-missing-parent"
    test "rules under a missing subscription -> 404 ResourceNotFound" do
      put_ns("sbns-r5")
      put_topic("sbns-r5", "t1")

      conn = put_rule("sbns-r5", "t1", "ghost", "r1", %{"sqlExpression" => "a = 'b'"})
      assert {404, "ResourceNotFound"} = {conn.status, code(conn)}
    end
  end

  # -- Evaluator tier ---------------------------------------------------------------

  describe "SQL filter evaluation" do
    @tag sb_rules: "sql-eval"
    test "equality on app property and sys.label; missing property is false" do
      {:ok, f} = SbRules.parse_sql("ordertype = 'priority'")
      assert SbRules.filter_matches_for_test?(f, %{app_props: %{"ordertype" => "priority"}})
      refute SbRules.filter_matches_for_test?(f, %{app_props: %{"ordertype" => "bulk"}})
      refute SbRules.filter_matches_for_test?(f, %{app_props: %{}})

      {:ok, f2} = SbRules.parse_sql("sys.label = 'vip'")
      assert SbRules.filter_matches_for_test?(f2, %{label: "vip"})
      refute SbRules.filter_matches_for_test?(f2, %{label: "other"})

      {:ok, f3} = SbRules.parse_sql("n = 42")
      assert SbRules.filter_matches_for_test?(f3, %{app_props: %{"n" => 42}})
      refute SbRules.filter_matches_for_test?(f3, %{app_props: %{"n" => "42"}})
    end

    @tag sb_rules: "sql-eval"
    test "AND/OR and parentheses" do
      {:ok, f} = SbRules.parse_sql("(a = 'x' OR b = 'y') AND sys.label = 'hot'")

      assert SbRules.filter_matches_for_test?(f, %{
               app_props: %{"a" => "x"},
               label: "hot"
             })

      assert SbRules.filter_matches_for_test?(f, %{
               app_props: %{"b" => "y"},
               label: "hot"
             })

      refute SbRules.filter_matches_for_test?(f, %{
               app_props: %{"a" => "x"},
               label: "cold"
             })
    end

    @tag sb_rules: "sql-eval"
    test "EXISTS" do
      {:ok, f} = SbRules.parse_sql("EXISTS(trace_id)")

      assert SbRules.filter_matches_for_test?(f, %{app_props: %{"trace_id" => "abc"}})
      refute SbRules.filter_matches_for_test?(f, %{app_props: %{}})
    end

    @tag sb_rules: "sql-parse-refusal"
    test "fail-closed parse refusals on unsupported constructs" do
      for bad <- [
            "ordertype LIKE 'p%'",
            "a = 'x' AND",
            "CONTAINS(a, 'x')",
            "sys.time > '2026-01-01'",
            ""
          ] do
        assert {:error, _} = SbRules.parse_sql(bad), "expected refusal: #{inspect(bad)}"
      end
    end

    @tag sb_rules: "correlation-filter"
    test "correlation filter matches message_id and app properties" do
      props = %{"filter" => %{"correlationId" => "corr-1", "properties" => %{"tenant" => "acme"}}}
      assert {:ok, {:correlation, _}} = SbRules.compile(props)

      msg = %{message_id: "corr-1", app_props: %{"tenant" => "acme"}}
      other = %{message_id: "other", app_props: %{"tenant" => "acme"}}

      assert SbRules.subscription_admits?([%{"properties" => props}], msg)
      refute SbRules.subscription_admits?([%{"properties" => props}], other)
    end
  end

  # -- Delivery semantics ------------------------------------------------------------

  describe "delivery fan-out" do
    @tag sb_rules: "fan-out"
    test "matching message delivered to exactly the sql-filter subscription; action overrides label" do
      setup_topic_sub("sbns-f1", "t1", "s-true")
      setup_topic_sub("sbns-f1", "t1", "s-sql")

      put_rule("sbns-f1", "t1", "s-sql", "vip", %{"sqlExpression" => "tier = 'gold'"}, %{
        "sqlExpression" => "SET sys.label = 'routed'"
      })

      msg = %{body: "payload", message_id: "m-1", app_props: %{"tier" => "gold"}, label: "orig"}

      delivered = SbRules.fan_out("/subscriptions/sub-1/resourceGroups/rg-1", "sbns-f1", "t1", msg)

      assert Enum.sort(delivered) == ["s-sql", "s-true"]

      # matching message landed in BOTH queues (true-filter sub admits all)
      {:ok, true_msgs} = Smalt.Amqp.QueueStore.peek("t1/subscriptions/s-true")
      assert [%{body: "payload"}] = true_msgs

      {:ok, [sql_msg]} = Smalt.Amqp.QueueStore.peek("t1/subscriptions/s-sql")

      # action overrode the label via SET sys.label = 'routed'
      assert sql_msg.app_props["label"] == "routed"
    end

    @tag sb_rules: "fan-out-skip"
    test "non-matching message skipped (not DLQ'd) by the sql-filter subscription" do
      setup_topic_sub("sbns-f2", "t1", "s-true")
      setup_topic_sub("sbns-f2", "t1", "s-sql")

      put_rule("sbns-f2", "t1", "s-sql", "vip", %{"sqlExpression" => "tier = 'gold'"})

      msg = %{body: "no-match", message_id: "m-2", app_props: %{"tier" => "bronze"}}

      delivered =
        SbRules.fan_out("/subscriptions/sub-1/resourceGroups/rg-1", "sbns-f2", "t1", msg)

      assert delivered == ["s-true"]

      # s-sql queue has NOTHING stored for it
      {:ok, []} = Smalt.Amqp.QueueStore.peek("t1/subscriptions/s-sql")
    end

    @tag sb_rules: "fan-out-default"
    test "subscription with no rules admits everything (default true-filter)" do
      setup_topic_sub("sbns-f3", "t1", "only")

      delivered =
        SbRules.fan_out("/subscriptions/sub-1/resourceGroups/rg-1", "sbns-f3", "t1", %{
          body: "x",
          message_id: "m-3",
          app_props: %{}
        })

      assert delivered == ["only"]
    end
  end

  # -- Helpers ------------------------------------------------------------------------

  defp put_ns(ns) do
    conn(:put, "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}?api-version=2021-04-01", %{
      "location" => "eastus",
      "properties" => %{"skuName" => "Standard"}
    })
    |> Router.call(@opts)
    |> assert_status_in([200, 201])
  end

  defp put_topic(ns, topic) do
    conn(:put, "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}/topics/#{topic}?api-version=2021-04-01", %{
      "location" => "eastus"
    })
    |> Router.call(@opts)
    |> assert_status_in([200, 201])
  end

  defp put_sub(ns, topic, sub) do
    conn(:put, "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub}?api-version=2021-04-01", %{
      "location" => "eastus"
    })
    |> Router.call(@opts)
    |> assert_status_in([200, 201])
  end

  defp setup_topic_sub(ns, topic, sub) do
    put_ns(ns)
    put_topic(ns, topic)
    put_sub(ns, topic, sub)
  end

  defp rule_uri(ns, topic, sub, rule) do
    base =
      "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub}/rules"

    if rule, do: "#{base}/#{rule}", else: base
  end

  defp rule_req(:list, ns, topic, sub, nil),
    do: rule_req(:get, ns, topic, sub, nil)

  defp rule_req(verb, ns, topic, sub, rule) do
    conn(verb, rule_uri(ns, topic, sub, rule) <> "?api-version=2021-04-01", %{})
    |> Router.call(@opts)
  end

  defp put_rule(ns, topic, sub, rule, filter, action \\ nil) do
    props = %{"filter" => filter}
    props = if action, do: Map.put(props, "action", action), else: props

    conn(:put, rule_uri(ns, topic, sub, rule) <> "?api-version=2021-04-01", %{
      "name" => rule,
      "properties" => props
    })
    |> Router.call(@opts)
  end

  defp assert_status(conn, want) do
    assert conn.status == want, "expected #{want}, got #{conn.status}: #{conn.resp_body}"
    conn
  end

  defp assert_status_in(conn, wants) do
    assert conn.status in wants, "expected one of #{inspect(wants)}, got #{conn.status}: #{conn.resp_body}"
    conn
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]["code"]
end
