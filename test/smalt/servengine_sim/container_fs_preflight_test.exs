defmodule Smalt.ServengineSim.ContainerFsPreflightTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.ContainerFsPreflight
  alias Smalt.ServengineSim.ContainerFsPreflight.Error

  @valid_env %{
    "XAAS_A2A_DATA_DIR" => "/app/data/a2a",
    "XAAS_PPLAN_DETS_PATH" => "/app/data/pplan_durable_store"
  }

  @valid_ash_a2a [
    receipt_store_ekv_opts: [data_dir: "/app/data/a2a/receipt_store_ekv", cluster_size: 3],
    authority_broker:
      {AshA2A.Authority.Broker.Ekv, data_dir: "/app/data/a2a/authority_broker_ekv", cluster_size: 3}
  ]

  describe "USER nobody accept paths" do
    test "passes when XAAS_A2A_DATA_DIR and XAAS_PPLAN_DETS_PATH are under /app and cluster_size >= 3" do
      assert {:ok, report} =
               ContainerFsPreflight.check(
                 env: @valid_env,
                 ash_a2a: @valid_ash_a2a
               )

      assert report.status == :ok
      assert report.user.name == "nobody"
      assert report.user.uid == 65_534
      assert report.xaas_a2a_data_dir == "/app/data/a2a"
      assert report.xaas_pplan_dets_path == "/app/data/pplan_durable_store"
      assert report.cluster_size == 3
      assert report.authority_broker_cluster_size == 3
      assert report.probed_on_disk? == false
    end

    test "passes with real on-disk write probe inside sandbox_root mapped to /app" do
      sandbox =
        Path.join(
          System.tmp_dir!(),
          "smalt_container_preflight_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(sandbox, "app"))
      on_exit(fn -> File.rm_rf!(sandbox) end)

      report =
        ContainerFsPreflight.check!(
          env: @valid_env,
          ash_a2a: [receipt_store_ekv_opts: [cluster_size: 5]],
          sandbox_root: sandbox
        )

      assert report.probed_on_disk? == true
      assert report.cluster_size == 5
      assert File.dir?(Path.join(sandbox, "app/data/a2a"))
      assert File.dir?(Path.join(sandbox, "app/data"))
      # Probe artifacts must be cleaned up after preflight.
      assert Path.wildcard(Path.join(sandbox, "**/.preflight_probe_*")) == []
    end

    test "accepts ASH_A2A_EKV_CLUSTER_SIZE=3 via env fallback" do
      env = Map.put(@valid_env, "ASH_A2A_EKV_CLUSTER_SIZE", "3")
      assert {:ok, %{cluster_size: 3}} = ContainerFsPreflight.check(env: env)
    end
  end

  describe "/var/lib/xaas and non-/app path refusals" do
    test "refuses /var/lib/xaas and /var/lib/xaas/a2a for XAAS_A2A_DATA_DIR" do
      for bad_path <- ["/var/lib/xaas", "/var/lib/xaas/a2a", "/app/../var/lib/xaas/a2a"] do
        env = Map.put(@valid_env, "XAAS_A2A_DATA_DIR", bad_path)

        assert {:error, violations} =
                 ContainerFsPreflight.check(env: env, ash_a2a: @valid_ash_a2a)

        assert {:refused_var_lib_xaas, "XAAS_A2A_DATA_DIR", expanded} =
                 Enum.find(violations, &(elem(&1, 0) == :refused_var_lib_xaas))

        assert String.starts_with?(expanded, "/var/lib/xaas")
      end
    end

    test "refuses /var/lib/xaas/pplan_durable_store for XAAS_PPLAN_DETS_PATH" do
      env = Map.put(@valid_env, "XAAS_PPLAN_DETS_PATH", "/var/lib/xaas/pplan_durable_store")

      assert {:error, [{:refused_var_lib_xaas, "XAAS_PPLAN_DETS_PATH", "/var/lib/xaas/pplan_durable_store"}]} =
               ContainerFsPreflight.check(env: env, ash_a2a: @valid_ash_a2a)
    end

    test "refuses paths outside /app (e.g. /tmp, /nonexistent, /app_other, relative)" do
      for bad <- ["/tmp/xaas-a2a", "/nonexistent/.xaas/a2a", "/app_other/a2a"] do
        env = Map.put(@valid_env, "XAAS_A2A_DATA_DIR", bad)

        assert {:error, [{:outside_app_root, "XAAS_A2A_DATA_DIR", ^bad}]} =
                 ContainerFsPreflight.check(env: env, ash_a2a: @valid_ash_a2a)
      end

      env_rel = Map.put(@valid_env, "XAAS_PPLAN_DETS_PATH", "data/pplan_durable_store")

      assert {:error, [{:relative_path, "XAAS_PPLAN_DETS_PATH", "data/pplan_durable_store"}]} =
               ContainerFsPreflight.check(env: env_rel, ash_a2a: @valid_ash_a2a)
    end

    test "refuses missing or blank XAAS_A2A_DATA_DIR and XAAS_PPLAN_DETS_PATH under USER nobody" do
      env = %{"XAAS_A2A_DATA_DIR" => "", "XAAS_PPLAN_DETS_PATH" => nil}

      assert {:error, violations} = ContainerFsPreflight.check(env: env, ash_a2a: @valid_ash_a2a)
      assert {:missing_env, "XAAS_A2A_DATA_DIR"} in violations
      assert {:missing_env, "XAAS_PPLAN_DETS_PATH"} in violations
    end

    test "refuses exact path collision between XAAS_A2A_DATA_DIR and XAAS_PPLAN_DETS_PATH" do
      env = %{
        "XAAS_A2A_DATA_DIR" => "/app/shared",
        "XAAS_PPLAN_DETS_PATH" => "/app/shared"
      }

      assert {:error, [{:path_collision, "/app/shared"}]} =
               ContainerFsPreflight.check(env: env, ash_a2a: @valid_ash_a2a)
    end
  end

  describe "USER nobody writability enforcement" do
    test "refuses root user" do
      assert {:error, [{:root_user_forbidden, %{name: "root", uid: 0}}]} =
               ContainerFsPreflight.check(
                 user: "root",
                 env: @valid_env,
                 ash_a2a: @valid_ash_a2a
               )
    end

    test "refuses read-only /app subpath in virtual mode" do
      env = Map.put(@valid_env, "XAAS_A2A_DATA_DIR", "/app/locked/a2a")

      assert {:error, [{:not_writable, "XAAS_A2A_DATA_DIR", "/app/locked/a2a", :eacces}]} =
               ContainerFsPreflight.check(
                 env: env,
                 ash_a2a: @valid_ash_a2a,
                 readonly_paths: ["/app/locked"]
               )
    end

    test "refuses read-only /app directory on disk in sandbox_root" do
      sandbox =
        Path.join(
          System.tmp_dir!(),
          "smalt_container_ro_#{System.unique_integer([:positive])}"
        )

      locked_dir = Path.join(sandbox, "app/locked")
      File.mkdir_p!(locked_dir)
      File.chmod!(locked_dir, 0o555)

      on_exit(fn ->
        _ = File.chmod(locked_dir, 0o755)
        File.rm_rf!(sandbox)
      end)

      env = %{
        "XAAS_A2A_DATA_DIR" => "/app/locked",
        "XAAS_PPLAN_DETS_PATH" => "/app/data/pplan_durable_store"
      }

      assert {:error, [{:not_writable, "XAAS_A2A_DATA_DIR", "/app/locked", :eacces}]} =
               ContainerFsPreflight.check(
                 env: env,
                 ash_a2a: @valid_ash_a2a,
                 sandbox_root: sandbox
               )
    end
  end

  describe "ash_a2a cluster_size >= 3 check" do
    test "defaults to 1 and refuses when cluster_size is omitted" do
      assert {:error, [{:insufficient_cluster_size, :receipt_store, 1}]} =
               ContainerFsPreflight.check(env: @valid_env, ash_a2a: [])
    end

    test "refuses cluster_size 1 or 2 on receipt_store or authority_broker" do
      assert {:error, [{:insufficient_cluster_size, :receipt_store, 2}]} =
               ContainerFsPreflight.check(
                 env: @valid_env,
                 ash_a2a: [receipt_store_ekv_opts: [cluster_size: 2]]
               )

      assert {:error, [{:insufficient_cluster_size, :authority_broker, 1}]} =
               ContainerFsPreflight.check(
                 env: @valid_env,
                 ash_a2a: [
                   receipt_store_ekv_opts: [cluster_size: 3],
                   authority_broker: {AshA2A.Authority.Broker.Ekv, data_dir: "/app/data/broker", cluster_size: 1}
                 ]
               )
    end

    test "refuses non-integer ASH_A2A_EKV_CLUSTER_SIZE" do
      env = Map.put(@valid_env, "ASH_A2A_EKV_CLUSTER_SIZE", "quorum")

      assert {:error, [{:invalid_cluster_size, :receipt_store, "quorum"}]} =
               ContainerFsPreflight.check(env: env)
    end

    test "check!/1 raises ContainerFsPreflight.Error with violation details" do
      err =
        assert_raise Error, fn ->
          ContainerFsPreflight.check!(
            env: %{
              "XAAS_A2A_DATA_DIR" => "/var/lib/xaas/a2a",
              "XAAS_PPLAN_DETS_PATH" => "/app/data/pplan"
            },
            ash_a2a: [receipt_store_ekv_opts: [cluster_size: 1]]
          )
        end

      msg = Exception.message(err)
      assert msg =~ "refused_var_lib_xaas"
      assert msg =~ "insufficient_cluster_size"
    end
  end
end
