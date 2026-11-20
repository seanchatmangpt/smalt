defmodule Smalt.ServengineSim.RlsPoolSimTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.RlsPoolSim
  alias Smalt.ServengineSim.RlsPoolSim.Conn

  @tenant_a "11111111-1111-1111-1111-111111111111"
  @tenant_b "22222222-2222-2222-2222-222222222222"

  @rows [
    %{id: 1, tenant_id: @tenant_a, name: "alpha"},
    %{id: 2, tenant_id: @tenant_b, name: "beta"}
  ]

  describe "PG16 app.current_tenant_id '' vs NULL and NULLIF(..., '')::uuid" do
    test "fresh connection returns NULL (nil) and fails closed under both raw_cast and nullif_cast" do
      conn = RlsPoolSim.new_conn()

      assert {:error, {:pg_error, "42704", :undefined_object, _}} =
               RlsPoolSim.current_setting(conn, "app.current_tenant_id", false)

      assert {:ok, nil} = RlsPoolSim.current_setting(conn, "app.current_tenant_id", true)
      assert {:ok, nil} = RlsPoolSim.eval_tenant_id(conn, :raw_cast)
      assert {:ok, nil} = RlsPoolSim.eval_tenant_id(conn, :nullif_cast)

      assert {:ok, []} = RlsPoolSim.query_rows(conn, @rows, policy_mode: :raw_cast)
      assert {:ok, []} = RlsPoolSim.query_rows(conn, @rows, policy_mode: :nullif_cast)

      assert {:error, {:pg_error, "42501", :insufficient_privilege, _}} =
               RlsPoolSim.insert_row(conn, %{id: 3, tenant_id: @tenant_a},
                 policy_mode: :nullif_cast
               )
    end

    test "reused pooled connection yields '' after SET LOCAL + COMMIT; raw_cast crashes 22P02 while nullif_cast fails closed" do
      pool = RlsPoolSim.new_pool(size: 1, checkin_reset: :none)

      # Request 1: sets tenant A via SET LOCAL inside a transaction and commits.
      {{:ok, rows_a}, pool} =
        RlsPoolSim.with_conn(pool, fn conn ->
          {:ok, res, committed} =
            RlsPoolSim.transaction(conn, fn tx ->
              {:ok, tx} = RlsPoolSim.set_local(tx, "app.current_tenant_id", @tenant_a)
              {:ok, selected} = RlsPoolSim.query_rows(tx, @rows, policy_mode: :raw_cast)
              {:ok, selected, tx}
            end)

          {{:ok, res}, committed}
        end)

      assert [%{id: 1, tenant_id: @tenant_a}] = rows_a

      # Request 2: reuses the exact same pooled connection without setting tenant_id.
      # PG16 leaves the custom placeholder GUC as "" (not nil/NULL).
      {:ok, reused_conn, pool} = RlsPoolSim.checkout(pool)

      assert {:ok, ""} = RlsPoolSim.current_setting(reused_conn, "app.current_tenant_id", true)
      assert {:ok, ""} = RlsPoolSim.current_setting(reused_conn, "app.current_tenant_id", false)

      inspection = RlsPoolSim.inspect_pool_conn(reused_conn)
      assert inspection.raw_cast_hazard?
      assert inspection.empty_placeholder_gucs == ["app.current_tenant_id"]

      # Raw ::uuid cast blows up on "" with 22P02.
      assert {:error, {:pg_error, "22P02", :invalid_text_representation, _}} =
               RlsPoolSim.eval_tenant_id(reused_conn, :raw_cast)

      assert {:error, {:pg_error, "22P02", :invalid_text_representation, _}} =
               RlsPoolSim.query_rows(reused_conn, @rows, policy_mode: :raw_cast)

      assert {:error, {:pg_error, "22P02", :invalid_text_representation, _}} =
               RlsPoolSim.insert_row(reused_conn, %{id: 3, tenant_id: @tenant_a},
                 policy_mode: :raw_cast
               )

      # NULLIF(current_setting('app.current_tenant_id', true), '')::uuid treats "" as NULL and fails closed.
      assert {:ok, nil} = RlsPoolSim.eval_tenant_id(reused_conn, :nullif_cast)
      assert {:ok, []} = RlsPoolSim.query_rows(reused_conn, @rows, policy_mode: :nullif_cast)

      assert {:error, {:pg_error, "42501", :insufficient_privilege, _}} =
               RlsPoolSim.insert_row(reused_conn, %{id: 3, tenant_id: @tenant_a},
                 policy_mode: :nullif_cast
               )

      assert {:ok, _pool} = RlsPoolSim.checkin(pool, reused_conn)
    end

    test "ROLLBACK, RESET ALL, and DISCARD ALL still leave previously-set custom GUC as '' on PG16" do
      pool = RlsPoolSim.new_pool(size: 1, checkin_reset: :reset_all)

      {_, pool} =
        RlsPoolSim.with_conn(pool, fn conn ->
          {:rollback, :abort, rolled_back} =
            RlsPoolSim.transaction(conn, fn tx ->
              {:ok, tx} = RlsPoolSim.set_local(tx, "app.current_tenant_id", @tenant_a)
              {:rollback, :abort, tx}
            end)

          {:rolled_back, rolled_back}
        end)

      {:ok, conn_after_reset, pool} = RlsPoolSim.checkout(pool)

      assert {:ok, ""} =
               RlsPoolSim.current_setting(conn_after_reset, "app.current_tenant_id", true)

      assert {:error, {:pg_error, "22P02", _, _}} =
               RlsPoolSim.eval_tenant_id(conn_after_reset, :raw_cast)

      assert {:ok, nil} = RlsPoolSim.eval_tenant_id(conn_after_reset, :nullif_cast)

      {:ok, discarded} = RlsPoolSim.discard_all(conn_after_reset)
      assert {:ok, ""} = RlsPoolSim.current_setting(discarded, "app.current_tenant_id", true)

      assert {:ok, _} = RlsPoolSim.checkin(pool, discarded)
    end

    test "fresh_conn pool reset returns connection to NULL, and DISCARD ALL refuses inside tx" do
      pool = RlsPoolSim.new_pool(size: 1, checkin_reset: :fresh_conn)

      {_, pool} =
        RlsPoolSim.with_conn(pool, fn conn ->
          {:ok, _, committed} =
            RlsPoolSim.transaction(conn, fn tx ->
              {:ok, tx} = RlsPoolSim.set_local(tx, "app.current_tenant_id", @tenant_a)
              {:ok, :done, tx}
            end)

          {:ok, committed}
        end)

      {:ok, fresh_again, _pool} = RlsPoolSim.checkout(pool)
      assert {:ok, nil} = RlsPoolSim.current_setting(fresh_again, "app.current_tenant_id", true)

      {:ok, in_tx} = RlsPoolSim.begin_tx(fresh_again)

      assert {:error, {:pg_error, "25001", :active_sql_transaction, _}} =
               RlsPoolSim.discard_all(in_tx)
    end

    test "validates UUID syntax (including malformed non-empty strings) and SET LOCAL tx requirement" do
      conn = RlsPoolSim.new_conn()

      assert {:error, {:pg_error, "25P01", :no_active_sql_transaction, _}} =
               RlsPoolSim.set_local(conn, "app.current_tenant_id", @tenant_a)

      # set_config(..., is_local=true) outside a tx registers placeholder as "" after statement
      {:ok, @tenant_a, after_stmt} =
        RlsPoolSim.set_config(conn, "app.current_tenant_id", @tenant_a, true)

      assert {:ok, ""} = RlsPoolSim.current_setting(after_stmt, "app.current_tenant_id", true)

      # Malformed non-empty tenant ID fails with 22P02 even under :nullif_cast
      {:ok, bad_conn} =
        RlsPoolSim.begin_tx(conn)
        |> then(fn {:ok, tx} ->
          RlsPoolSim.set_local(tx, "app.current_tenant_id", "not-a-uuid")
        end)

      assert {:error, {:pg_error, "22P02", :invalid_text_representation, _}} =
               RlsPoolSim.eval_tenant_id(bad_conn, :nullif_cast)

      # Uppercase/braced/compact UUIDs normalize to canonical lowercase 8-4-4-4-12
      compact_upper = String.upcase(String.replace(@tenant_b, "-", ""))

      {:ok, braced_tx} =
        RlsPoolSim.set_local(bad_conn, "app.current_tenant_id", "{#{compact_upper}}")

      assert {:ok, @tenant_b} = RlsPoolSim.eval_tenant_id(braced_tx, :nullif_cast)
      assert {:ok, [%{id: 2, tenant_id: @tenant_b}]} = RlsPoolSim.query_rows(braced_tx, @rows)
    end

    test "session-level SET leaks tenant across pool checkout unless checkin_reset clears it" do
      leaky_pool = RlsPoolSim.new_pool(size: 1, checkin_reset: :none)

      {conn_before, leaky_pool} =
        RlsPoolSim.with_conn(leaky_pool, fn conn ->
          {:ok, set_conn} = RlsPoolSim.set_session(conn, "app.current_tenant_id", @tenant_a)
          {conn, set_conn}
        end)

      {:ok, leaked_next, _leaky_pool} = RlsPoolSim.checkout(leaky_pool)
      assert {:ok, [%{id: 1, tenant_id: @tenant_a}]} = RlsPoolSim.query_rows(leaked_next, @rows)

      assert {:leak_detected, report} = RlsPoolSim.detect_outer_tx_leak(conn_before, leaked_next)
      assert report.reason == :session_guc_leak
      assert report.leaked_gucs == ["app.current_tenant_id"]

      safe_pool = RlsPoolSim.new_pool(size: 1, checkin_reset: :reset_all)

      {_, safe_pool} =
        RlsPoolSim.with_conn(safe_pool, fn conn ->
          {:ok, set_conn} = RlsPoolSim.set_session(conn, "app.current_tenant_id", @tenant_a)
          {:ok, set_conn}
        end)

      {:ok, reset_next, _safe_pool} = RlsPoolSim.checkout(safe_pool)
      assert {:ok, ""} = RlsPoolSim.current_setting(reset_next, "app.current_tenant_id", true)
      assert {:ok, []} = RlsPoolSim.query_rows(reset_next, @rows, policy_mode: :nullif_cast)
    end
  end

  describe "with_platform_scope and outer-transaction leak detection" do
    test "top-level with_platform_scope (tx_depth == 0) elevates only for the transaction and commits cleanly" do
      conn = RlsPoolSim.new_conn()

      for mode <- [:reject_outer_tx, :detect, :naive, :restore] do
        {:ok, scoped_rows, after_conn} =
          RlsPoolSim.with_platform_scope(
            conn,
            fn scoped ->
              assert RlsPoolSim.platform_scope?(scoped)
              {:ok, all} = RlsPoolSim.query_rows(scoped, @rows)
              {:ok, all, scoped}
            end,
            mode: mode
          )

        assert length(scoped_rows) == 2
        assert after_conn.tx_depth == 0
        refute RlsPoolSim.platform_scope?(after_conn)
        assert :ok = RlsPoolSim.detect_outer_tx_leak(conn, after_conn)
        assert {:ok, []} = RlsPoolSim.query_rows(after_conn, @rows, policy_mode: :nullif_cast)
      end
    end

    test "naive with_platform_scope inside an outer transaction leaks platform_scope via RELEASE SAVEPOINT" do
      conn = RlsPoolSim.new_conn()

      {:ok, {_inside, leaked_after_scope}, committed_outer} =
        RlsPoolSim.transaction(conn, fn outer_tx ->
          {:ok, outer_tx} = RlsPoolSim.set_local(outer_tx, "app.current_tenant_id", @tenant_a)
          assert {:ok, [%{id: 1}]} = RlsPoolSim.query_rows(outer_tx, @rows)

          # Nested with_platform_scope in :naive mode uses SAVEPOINT + SET LOCAL + RELEASE SAVEPOINT.
          {:ok, inside_rows, post_scope_outer} =
            RlsPoolSim.with_platform_scope(
              outer_tx,
              fn scoped ->
                {:ok, all} = RlsPoolSim.query_rows(scoped, @rows)
                {:ok, all, scoped}
              end,
              mode: :naive
            )

          assert length(inside_rows) == 2
          assert post_scope_outer.tx_depth == 1

          # LEAK: app.platform_scope = "true" persisted past RELEASE SAVEPOINT into the outer tx!
          assert RlsPoolSim.platform_scope?(post_scope_outer)

          assert {:ok, [%{id: 1}, %{id: 2}]} = RlsPoolSim.query_rows(post_scope_outer, @rows)

          assert {:leak_detected, leak_report} =
                   RlsPoolSim.detect_outer_tx_leak(outer_tx, post_scope_outer)

          assert leak_report.reason == :outer_transaction_leak
          assert leak_report.leaked_gucs == ["app.platform_scope"]

          assert [%{kind: :platform_scope_leaked, before: nil, after: "true", tx_depth: 1}] =
                   leak_report.findings

          {:ok, {inside_rows, post_scope_outer}, post_scope_outer}
        end)

      assert %Conn{tx_depth: 0} = committed_outer
      refute RlsPoolSim.platform_scope?(committed_outer)
      assert leaked_after_scope.tx_depth == 1
    end

    test "naive with_platform_scope with clear_tenant: true leaks BOTH platform_scope and cleared tenant_id" do
      conn = RlsPoolSim.new_conn()
      {:ok, outer_tx} = RlsPoolSim.begin_tx(conn)
      {:ok, outer_tx} = RlsPoolSim.set_local(outer_tx, "app.current_tenant_id", @tenant_a)

      {:ok, :done, leaked} =
        RlsPoolSim.with_platform_scope(
          outer_tx,
          fn scoped -> {:ok, :done, scoped} end,
          mode: :naive,
          clear_tenant: true
        )

      assert {:leak_detected, report} = RlsPoolSim.detect_outer_tx_leak(outer_tx, leaked)
      assert report.reason == :outer_transaction_leak
      assert Enum.sort(report.leaked_gucs) == ["app.current_tenant_id", "app.platform_scope"]
      assert {:ok, ""} = RlsPoolSim.current_setting(leaked, "app.current_tenant_id", true)
    end

    test "reject_outer_tx mode (default) refuses up front when outer transaction is active" do
      {:ok, outer_tx} = RlsPoolSim.new_conn() |> RlsPoolSim.begin_tx()
      {:ok, outer_tx} = RlsPoolSim.set_local(outer_tx, "app.current_tenant_id", @tenant_a)

      assert {:refused, refusal, returned_conn} =
               RlsPoolSim.with_platform_scope(outer_tx, fn scoped ->
                 flunk("callback must not execute when outer transaction is active")
                 {:ok, :never, scoped}
               end)

      assert refusal.reason == :outer_transaction_active
      assert refusal.tx_depth == 1
      assert returned_conn == outer_tx
      refute RlsPoolSim.platform_scope?(returned_conn)
      assert {:ok, [%{id: 1}]} = RlsPoolSim.query_rows(returned_conn, @rows)
    end

    test "detect mode refuses with leak_report when inner SET LOCAL leaks into outer transaction" do
      {:ok, outer_tx} = RlsPoolSim.new_conn() |> RlsPoolSim.begin_tx()
      {:ok, outer_tx} = RlsPoolSim.set_local(outer_tx, "app.current_tenant_id", @tenant_a)

      assert {:refused, leak_report, after_conn} =
               RlsPoolSim.with_platform_scope(
                 outer_tx,
                 fn scoped -> {:ok, :ran, scoped} end,
                 mode: :detect
               )

      assert leak_report.reason == :outer_transaction_leak
      assert leak_report.leaked_gucs == ["app.platform_scope"]
      assert after_conn.tx_depth == 1
    end

    test "restore mode and inner savepoint rollback keep outer-transaction tenant isolation intact" do
      {:ok, outer_tx} = RlsPoolSim.new_conn() |> RlsPoolSim.begin_tx()
      {:ok, outer_tx} = RlsPoolSim.set_local(outer_tx, "app.current_tenant_id", @tenant_a)

      # :restore saves/restores app.platform_scope and app.current_tenant_id before releasing savepoint
      {:ok, scoped_rows, restored_outer} =
        RlsPoolSim.with_platform_scope(
          outer_tx,
          fn scoped ->
            assert RlsPoolSim.platform_scope?(scoped)
            assert {:ok, ""} = RlsPoolSim.current_setting(scoped, "app.current_tenant_id", true)
            {:ok, all} = RlsPoolSim.query_rows(scoped, @rows)
            {:ok, all, scoped}
          end,
          mode: :restore,
          clear_tenant: true
        )

      assert length(scoped_rows) == 2
      refute RlsPoolSim.platform_scope?(restored_outer)

      assert {:ok, @tenant_a} =
               RlsPoolSim.current_setting(restored_outer, "app.current_tenant_id", true)

      assert {:ok, [%{id: 1}]} = RlsPoolSim.query_rows(restored_outer, @rows)
      assert :ok = RlsPoolSim.detect_outer_tx_leak(outer_tx, restored_outer)

      # Inner savepoint rollback (ROLLBACK TO SAVEPOINT) also reverts SET LOCAL cleanly
      {:rollback, :boom, after_rollback} =
        RlsPoolSim.with_platform_scope(
          restored_outer,
          fn scoped ->
            assert RlsPoolSim.platform_scope?(scoped)
            {:rollback, :boom, scoped}
          end,
          mode: :naive
        )

      refute RlsPoolSim.platform_scope?(after_rollback)
      assert {:ok, [%{id: 1}]} = RlsPoolSim.query_rows(after_rollback, @rows)
      assert :ok = RlsPoolSim.detect_outer_tx_leak(restored_outer, after_rollback)
    end
  end
end
