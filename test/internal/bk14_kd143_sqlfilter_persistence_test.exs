# BK-14 court (internal tier): KD-143 sb-rules sqlFilter persistence.
#
# Defect: :smalt_sb_rules carried persisted: false in the generated
# Smalt.StoreTables registry, so Smalt.Store.DetsMirror never mirrored it —
# a substrate recycle dropped every stored subscription rule (sqlFilter
# gone, GET fell back to the trueFilter echo).
#
# Fix: smalt:persisted true for st-smalt_sb_rules in the
# smalt-substrate-pack ontology + `mix smalt.gen` regeneration.
#
# Chicago discipline: real Store rows, real DETS files in a real tmp dir,
# real ARM dispatch (Plug.Router.call, auth :anonymous in test env),
# real DetsMirror sync/restore. No mocks, no sleeps (bounded polls only).
#
# Context: solo (internal tier, in-process dispatch).

Code.require_file("poll_helper.exs", __DIR__)

defmodule Smalt.Internal.Bk14Kd143SqlfilterPersistenceTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import SmaltTest.Internal.Poll, only: [eventually: 1]

  alias Smalt.Store

  @table :smalt_sb_rules

  @created 201
  @ok 200

  @api_version "2021-04-01"
  @rg "/subscriptions/sub-bk14/resourceGroups/rg-bk14"
  @ns "ns-bk14"
  @topic "topic-bk14"
  @sub "sub-bk14"
  @base "#{@rg}/providers/Microsoft.ServiceBus/namespaces/#{@ns}"

  setup do
    assert {:ok, _} =
             eventually(fn ->
               case Process.whereis(Smalt.Store) do
                 pid when is_pid(pid) -> {:ok, pid}
                 nil ->
                   case Smalt.Store.start_link([]) do
                     {:ok, pid} -> {:ok, pid}
                     {:error, {:already_started, pid}} -> {:ok, pid}
                     {:error, other} -> {:refused, other}
                   end
               end
             end)

    ns_key = String.downcase(@base)

    Store.put(:smalt_resources, ns_key, %{
      "id" => @base,
      "name" => @ns,
      "type" => "Microsoft.ServiceBus/namespaces",
      "properties" => %{}
    })

    :ok
  end

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

  defp rules_key(rule),
    do: "#{@base}/topics/#{@topic}/subscriptions/#{@sub}/rules/#{rule}"

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

  defp put_rule(name, props) do
    arm_req(:put, rules_key(name), %{"properties" => props})
  end

  defp start_mirror(dir) do
    assert {:ok, pid} =
             Smalt.Store.DetsMirror.start_link(
               dir: dir,
               # Post-fix registry: the persisted set MUST now carry sb_rules.
               tables: Smalt.StoreTables.persisted_tables(),
               interval: 60_000,
               repair: false,
               name: Module.concat([Smalt.Store.DetsMirror, :"bk14_#{System.unique_integer([:positive])}"])
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  # -- Persistence court -----------------------------------------------------------

  @tag :smalt_internal
  test "NEGATIVE CONTROL (pre-fix registry shape): a mirror without sb_rules drops the rule on restore" do
    ensure_topic_sub()

    dir =
      Path.join(System.tmp_dir!(), "smalt-bk14-neg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # The PRE-FIX registry (persisted: false for :smalt_sb_rules) mirrored
    # exactly this set: sb_rules absent, so restore can never replay rules.
    pre_fix_tables = List.delete(Smalt.StoreTables.persisted_tables(), @table)

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(
        dir: dir,
        tables: pre_fix_tables,
        interval: 60_000,
        repair: false,
        name: Module.concat([Smalt.Store.DetsMirror, :"bk14neg_#{System.unique_integer([:positive])}"])
      )

    rules_prefix =
      String.downcase("#{@rg}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules/")

    assert put_rule("bk14-neg", %{
             "filterType" => "SqlFilter",
             "sqlFilter" => %{"sqlExpression" => "priority = 'high'"}
           }).status == @created

    assert :ok = Smalt.Store.DetsMirror.sync(pid)

    Enum.each(Store.list_prefix(@table, rules_prefix), fn r ->
      Store.delete(@table, String.downcase(r["id"]))
    end)

    assert {:ok, counts} = Smalt.Store.DetsMirror.restore(pid)
    # sb_rules is not in the mirror set: no replay, rule LOST (the KD-143
    # recycle defect, kept alive as a mechanical negative control).
    refute Map.has_key?(counts, @table)
    assert Store.list_prefix(@table, rules_prefix) == []
    assert arm_req(:get, rules_key("bk14-neg")).status == 404

    GenServer.stop(pid, :normal)
  end

  @tag :smalt_internal
  test "sqlFilter rule survives recycle: PUT -> sync -> ETS drop -> restore -> GET echoes sqlExpression" do
    ensure_topic_sub()

    dir =
      Path.join(System.tmp_dir!(), "smalt-bk14-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    mirror = start_mirror(dir)

    # Post-fix registry fence: sb_rules is in the mirrored set.
    assert @table in Smalt.StoreTables.persisted_tables()

    # Wire leg: PUT the Azure-typed sqlFilter rule body.
    assert put_rule("bk14-sql", %{
             "filterType" => "SqlFilter",
             "sqlFilter" => %{"sqlExpression" => "priority = 'high'"}
           }).status == @created

    # Real fsync to the real DETS file.
    assert :ok = Smalt.Store.DetsMirror.sync(mirror)

    # Recycle: the rule rows vanish from live ETS (restart semantics for a
    # memory-only table). Stored rule keys ride the /providers-less base.
    rules_prefix =
      String.downcase("#{@rg}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}/rules/")

    Enum.each(Store.list_prefix(@table, rules_prefix), fn r ->
      Store.delete(@table, String.downcase(r["id"]))
    end)

    assert Store.list_prefix(@table, rules_prefix) == []

    # Recovery: mirror replays the persisted rows back into ETS.
    assert {:ok, counts} = Smalt.Store.DetsMirror.restore(mirror)
    t = @table
    assert %{^t => n} = counts
    assert n >= 1

    # Wire face post-recovery: GET echoes the stored sqlExpression.
    get_conn = arm_req(:get, rules_key("bk14-sql"))
    assert get_conn.status == @ok

    echoed = Jason.decode!(get_conn.resp_body)
    assert echoed["properties"]["sqlFilter"]["sqlExpression"] == "priority = 'high'"
    assert echoed["properties"]["filter"]["sqlExpression"] == "priority = 'high'"

    # Evaluation face post-recovery: the restored filter evaluates, not just
    # echoes — matching message admitted, non-matching skipped.
    rules = Store.list_prefix(@table, rules_prefix)
    assert [%{"name" => "bk14-sql"} | _] = rules

    matching = %{app_props: %{"priority" => "high"}, body: "x"}
    non_matching = %{app_props: %{"priority" => "low"}, body: "x"}

    assert Smalt.SbRules.subscription_admits?(rules, matching)
    refute Smalt.SbRules.subscription_admits?(rules, non_matching)

    GenServer.stop(mirror, :normal)
  end

  # -- Adversarial leg: corrupt persisted rule --------------------------------------

  @tag :smalt_internal
  test "corrupt mirror file for sb_rules is a typed refusal, never a silent drop" do
    dir =
      Path.join(System.tmp_dir!(), "smalt-bk14-corrupt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "#{@table}.dets")
    File.write!(path, "definitely not a dets file — flipped header body")

    error = assert_raise(ArgumentError, fn -> start_mirror(dir) end)
    message = Exception.message(error)
    assert message =~ "corrupt_mirror"
    assert message =~ "smalt_sb_rules"
  end

  @tag :smalt_internal
  test "partial persisted rule (nil properties) is a clean skip, never a fan-out crash" do
    # Dedicated subscription so the sibling test's leaked rules can't admit.
    sub_p = "sub-bk14p"

    rules_prefix =
      String.downcase("#{@rg}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{sub_p}/rules/")

    # A partially-persisted rule record lands in ETS with no properties.
    partial_key = rules_prefix <> "bk14-partial"
    Store.put(@table, partial_key, %{"id" => partial_key, "name" => "bk14-partial"})

    rules = Store.list_prefix(@table, rules_prefix)

    # Typed fallback: unparsable properties -> non-match (skip), not a crash.
    assert match?({:error, :invalid_filter, _}, Smalt.SbRules.compile(nil))

    msg = %{app_props: %{"priority" => "high"}, body: "x"}

    # The partial rule never matches and never crashes subscription_admits?.
    refute Smalt.SbRules.subscription_admits?(rules, msg)

    Store.delete(@table, partial_key)
  end
end
