defmodule Smalt.ServengineSim.ProdEnvContractTest do
  use ExUnit.Case, async: true

  alias Smalt.ServengineSim.ProdEnvContract
  alias Smalt.ServengineSim.ProdEnvContract.Error

  defp b64_key(byte, len) do
    :binary.copy(<<byte>>, len) |> Base.encode64()
  end

  defp valid_env(overrides \\ %{}) do
    base = %{
      "DATABASE_URL" => "ecto://xaas_prod:super_db_secret_99@db.xaas.internal:5432/xaas_prod",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "CLOAK_KEY" => b64_key(0x11, 32),
      "BLIND_INDEX_KEY" => b64_key(0x22, 32),
      "USER_SOCKET_SALT" => "prod-socket-salt-0123456789",
      "TOKEN_SIGNING_SECRET" => "prod-jwt-signing-secret-0123456789abcdef",
      "A2A_BASE_URL" => "https://xaas.fnox.io/a2a",
      "XAAS_A2A_OUTBOX_KEY" => b64_key(0x33, 32),
      "XAAS_A2A_BINDING_KEY" => b64_key(0x44, 32),
      "XAAS_A2A_CLAIM_STORE_KEY" => b64_key(0x55, 32),
      "ADMIN_PASSWORD" => "prod-admin-passphrase-2026"
    }

    Map.merge(base, overrides)
  end

  defp valid_runtime_extras(overrides \\ %{}) do
    valid_env(
      Map.merge(
        %{
          "ONETIME_REVOKE_KEY" => String.duplicate("r", 48),
          "INTERNAL_API_TOKEN" => String.duplicate("t", 48),
          "XAAS_A2A_DATA_DIR" => "/app/var/a2a",
          "CORS_ORIGINS" => "https://app.xaas.fnox.io,https://admin.xaas.fnox.io"
        },
        overrides
      )
    )
  end

  describe "contract metadata" do
    test "exposes canonical required_vars and a2a_key_vars" do
      vars = ProdEnvContract.required_vars()

      for expected <- [
            "DATABASE_URL",
            "SECRET_KEY_BASE",
            "CLOAK_KEY",
            "BLIND_INDEX_KEY",
            "USER_SOCKET_SALT",
            "TOKEN_SIGNING_SECRET",
            "A2A_BASE_URL",
            "XAAS_A2A_OUTBOX_KEY",
            "XAAS_A2A_BINDING_KEY",
            "XAAS_A2A_CLAIM_STORE_KEY",
            "ADMIN_PASSWORD"
          ] do
        assert expected in vars
      end

      assert ProdEnvContract.a2a_key_vars() == [
               "XAAS_A2A_OUTBOX_KEY",
               "XAAS_A2A_BINDING_KEY",
               "XAAS_A2A_CLAIM_STORE_KEY"
             ]

      extra_vars = ProdEnvContract.required_vars(include_runtime_extras: true)
      assert "ONETIME_REVOKE_KEY" in extra_vars
      assert "INTERNAL_API_TOKEN" in extra_vars
      assert "XAAS_A2A_DATA_DIR" in extra_vars
      assert "CORS_ORIGINS" in extra_vars
    end
  end

  describe "valid :prod contracts" do
    test "admits a complete valid :prod env" do
      assert {:ok, report} = ProdEnvContract.validate(valid_env())
      assert report.status == :ok
      assert report.failed_vars == []
      assert report.findings == []
      assert report.counts == %{}
      assert length(report.passed_vars) == 11
      assert ProdEnvContract.format_report(report) == "PROD_ENV_CONTRACT OK: 11 variable(s) validated, 0 findings"
    end

    test "admits Cloud SQL socket_dir URL with localhost host" do
      env =
        valid_env(%{
          "DATABASE_URL" =>
            "ecto://xaas:db_secret@localhost/xaas_prod?socket_dir=/cloudsql/proj:us-central1:xaas-pg"
        })

      assert {:ok, report} = ProdEnvContract.validate(env)
      assert report.status == :ok
    end

    test "admits valid env with include_runtime_extras: true" do
      assert {:ok, report} =
               ProdEnvContract.validate(valid_runtime_extras(), include_runtime_extras: true)

      assert report.status == :ok
      assert length(report.passed_vars) == 15
    end
  end

  describe "DATABASE_URL contract" do
    test "refuses missing, blank, or placeholder DATABASE_URL" do
      for val <- [nil, "", "   ", "ecto://REPLACE_ME_USER:REPLACE_ME_PASSWORD@postgres:5432/prod"] do
        assert {:refused, report} = ProdEnvContract.validate(valid_env(%{"DATABASE_URL" => val}))
        assert "DATABASE_URL" in report.failed_vars
      end
    end

    test "refuses Cloud SQL ?host=/cloudsql/... bug (GAP-SIM-RUNTIME-DB-URL)" do
      bad_no_host = "ecto://xaas:pw@/xaas_prod?host=/cloudsql/proj:us-central1:xaas-pg"
      assert {:refused, report1} = ProdEnvContract.validate(valid_env(%{"DATABASE_URL" => bad_no_host}))
      kinds1 = Enum.map(report1.findings, & &1.kind)
      assert :missing_host in kinds1
      assert :cloudsql_query_host_unsupported in kinds1

      bad_with_host = "ecto://xaas:pw@localhost/xaas_prod?host=/cloudsql/proj:us-central1:xaas-pg"
      assert {:refused, report2} = ProdEnvContract.validate(valid_env(%{"DATABASE_URL" => bad_with_host}))
      assert Enum.any?(report2.findings, &(&1.kind == :cloudsql_query_host_unsupported))
    end

    test "refuses invalid scheme, missing credentials, missing database, and relative socket_dir" do
      for {bad_url, expected_kind} <- [
            {"https://xaas:pw@db.internal/xaas_prod", :invalid_scheme},
            {"ecto://db.internal/xaas_prod", :missing_credentials},
            {"ecto://xaas:@db.internal/xaas_prod", :missing_credentials},
            {"ecto://xaas:pw@db.internal/", :missing_database},
            {"ecto://xaas:pw@localhost/xaas_prod?socket_dir=relative/sock", :invalid_socket_dir}
          ] do
        assert {:refused, report} = ProdEnvContract.validate(valid_env(%{"DATABASE_URL" => bad_url}))
        assert Enum.any?(report.findings, &(&1.var == "DATABASE_URL" and &1.kind == expected_kind))
      end
    end
  end

  describe "SECRET_KEY_BASE contract" do
    test "refuses missing, short (<64 bytes), and committed dev/test literals" do
      assert {:refused, r_missing} = ProdEnvContract.validate(Map.delete(valid_env(), "SECRET_KEY_BASE"))
      assert Enum.any?(r_missing.findings, &(&1.var == "SECRET_KEY_BASE" and &1.kind == :missing))

      assert {:refused, r_short} =
               ProdEnvContract.validate(valid_env(%{"SECRET_KEY_BASE" => String.duplicate("a", 63)}))

      assert Enum.any?(r_short.findings, &(&1.var == "SECRET_KEY_BASE" and &1.kind == :too_short))

      for literal <- ProdEnvContract.dev_placeholders()["SECRET_KEY_BASE"] do
        assert {:refused, r_lit} = ProdEnvContract.validate(valid_env(%{"SECRET_KEY_BASE" => literal}))
        assert Enum.any?(r_lit.findings, &(&1.var == "SECRET_KEY_BASE" and &1.kind == :forbidden_dev_default))
      end
    end
  end

  describe "CLOAK_KEY and BLIND_INDEX_KEY contract" do
    test "refuses committed Xaas.Vault placeholder, invalid base64, and non-32-byte CLOAK_KEY" do
      [placeholder] = ProdEnvContract.dev_placeholders()["CLOAK_KEY"]

      assert {:refused, r_dev} = ProdEnvContract.validate(valid_env(%{"CLOAK_KEY" => placeholder}))
      assert Enum.any?(r_dev.findings, &(&1.var == "CLOAK_KEY" and &1.kind == :forbidden_dev_default))

      assert {:refused, r_b64} = ProdEnvContract.validate(valid_env(%{"CLOAK_KEY" => "not-valid-base64!!!"}))
      assert Enum.any?(r_b64.findings, &(&1.var == "CLOAK_KEY" and &1.kind == :invalid_base64))

      assert {:refused, r_len16} = ProdEnvContract.validate(valid_env(%{"CLOAK_KEY" => b64_key(0x11, 16)}))
      assert Enum.any?(r_len16.findings, &(&1.var == "CLOAK_KEY" and &1.kind == :invalid_key_length))

      assert {:refused, r_len64} = ProdEnvContract.validate(valid_env(%{"CLOAK_KEY" => b64_key(0x11, 64)}))
      assert Enum.any?(r_len64.findings, &(&1.var == "CLOAK_KEY" and &1.kind == :invalid_key_length))
    end

    test "refuses missing, invalid base64, short BLIND_INDEX_KEY, and key reuse with CLOAK_KEY" do
      assert {:refused, r_missing} = ProdEnvContract.validate(Map.delete(valid_env(), "BLIND_INDEX_KEY"))
      assert Enum.any?(r_missing.findings, &(&1.var == "BLIND_INDEX_KEY" and &1.kind == :missing))

      assert {:refused, r_short} = ProdEnvContract.validate(valid_env(%{"BLIND_INDEX_KEY" => b64_key(0x22, 16)}))
      assert Enum.any?(r_short.findings, &(&1.var == "BLIND_INDEX_KEY" and &1.kind == :invalid_key_length))

      same_key = b64_key(0x77, 32)

      assert {:refused, r_reuse} =
               ProdEnvContract.validate(valid_env(%{"CLOAK_KEY" => same_key, "BLIND_INDEX_KEY" => same_key}))

      assert Enum.any?(
               r_reuse.findings,
               &(&1.var == "BLIND_INDEX_KEY" and &1.kind == :key_reuse_with_cloak_key)
             )
    end
  end

  describe "USER_SOCKET_SALT and TOKEN_SIGNING_SECRET contracts" do
    test "refuses missing, short, or committed USER_SOCKET_SALT" do
      assert {:refused, r_short} = ProdEnvContract.validate(valid_env(%{"USER_SOCKET_SALT" => "short-salt"}))
      assert Enum.any?(r_short.findings, &(&1.var == "USER_SOCKET_SALT" and &1.kind == :too_short))

      for literal <- ProdEnvContract.dev_placeholders()["USER_SOCKET_SALT"] do
        assert {:refused, r_dev} = ProdEnvContract.validate(valid_env(%{"USER_SOCKET_SALT" => literal}))
        assert Enum.any?(r_dev.findings, &(&1.var == "USER_SOCKET_SALT" and &1.kind == :forbidden_dev_default))
      end
    end

    test "refuses missing, short (<32 bytes), and committed dev/test TOKEN_SIGNING_SECRET" do
      assert {:refused, r_missing} = ProdEnvContract.validate(Map.delete(valid_env(), "TOKEN_SIGNING_SECRET"))
      assert Enum.any?(r_missing.findings, &(&1.var == "TOKEN_SIGNING_SECRET" and &1.kind == :missing))

      assert {:refused, r_short} =
               ProdEnvContract.validate(valid_env(%{"TOKEN_SIGNING_SECRET" => String.duplicate("t", 31)}))

      assert Enum.any?(r_short.findings, &(&1.var == "TOKEN_SIGNING_SECRET" and &1.kind == :too_short))

      for literal <- ProdEnvContract.dev_placeholders()["TOKEN_SIGNING_SECRET"] do
        assert {:refused, r_dev} = ProdEnvContract.validate(valid_env(%{"TOKEN_SIGNING_SECRET" => literal}))

        assert Enum.any?(
                 r_dev.findings,
                 &(&1.var == "TOKEN_SIGNING_SECRET" and &1.kind == :forbidden_dev_default)
               )
      end
    end
  end

  describe "A2A_BASE_URL contract" do
    test "refuses missing, http, loopback/dev hosts, root path, trailing slash, or query/fragment" do
      for {bad_url, expected_kind} <- [
            {"http://xaas.fnox.io/a2a", :invalid_scheme},
            {"https://localhost/a2a", :forbidden_host},
            {"https://127.0.0.1/a2a", :forbidden_host},
            {"https://example.com/a2a", :forbidden_host},
            {"https://xaas.fnox.io", :invalid_path},
            {"https://xaas.fnox.io/", :invalid_path},
            {"https://xaas.fnox.io/a2a/", :trailing_slash},
            {"https://xaas.fnox.io/a2a?foo=bar", :unexpected_query_or_fragment},
            {"https://xaas.fnox.io/a2a#frag", :unexpected_query_or_fragment}
          ] do
        assert {:refused, report} = ProdEnvContract.validate(valid_env(%{"A2A_BASE_URL" => bad_url}))
        assert Enum.any?(report.findings, &(&1.var == "A2A_BASE_URL" and &1.kind == expected_kind))
      end
    end
  end

  describe "XAAS_A2A_*_KEY contract" do
    test "refuses missing, non-base64, short (<32 bytes), and dev literal keys" do
      for var <- ProdEnvContract.a2a_key_vars() do
        assert {:refused, r_miss} = ProdEnvContract.validate(Map.delete(valid_env(), var))
        assert Enum.any?(r_miss.findings, &(&1.var == var and &1.kind == :missing))

        assert {:refused, r_b64} = ProdEnvContract.validate(valid_env(%{var => "not-base64!"}))
        assert Enum.any?(r_b64.findings, &(&1.var == var and &1.kind == :invalid_base64))

        assert {:refused, r_len} = ProdEnvContract.validate(valid_env(%{var => b64_key(0x99, 31)}))
        assert Enum.any?(r_len.findings, &(&1.var == var and &1.kind == :invalid_key_length))

        [dev_lit] = ProdEnvContract.dev_placeholders()[var]
        assert {:refused, r_dev} = ProdEnvContract.validate(valid_env(%{var => dev_lit}))
        assert Enum.any?(r_dev.findings, &(&1.var == var and &1.kind == :forbidden_dev_default))
      end
    end

    test "discovers and validates additional XAAS_A2A_*_KEY variables present in env" do
      env = valid_env(%{"XAAS_A2A_EXTRA_KEY" => b64_key(0x66, 16)})
      assert {:refused, report} = ProdEnvContract.validate(env)
      assert "XAAS_A2A_EXTRA_KEY" in report.failed_vars
      assert Enum.any?(report.findings, &(&1.var == "XAAS_A2A_EXTRA_KEY" and &1.kind == :invalid_key_length))
    end
  end

  describe "ADMIN_PASSWORD contract" do
    test "refuses missing, blank, <8 bytes, weak defaults, and placeholders" do
      for {bad_pw, expected_kind} <- [
            {nil, :missing},
            {"   ", :missing},
            {"short7!", :too_short},
            {"  abc  ", :too_short},
            {"password", :weak_default},
            {"admin123", :weak_default},
            {"REPLACE_ME_admin", :placeholder_value}
          ] do
        assert {:refused, report} = ProdEnvContract.validate(valid_env(%{"ADMIN_PASSWORD" => bad_pw}))
        assert Enum.any?(report.findings, &(&1.var == "ADMIN_PASSWORD" and &1.kind == expected_kind))
      end
    end
  end

  describe "runtime extras and fail-closed API" do
    test "refuses ephemeral XAAS_A2A_DATA_DIR and wildcard/insecure CORS_ORIGINS" do
      env =
        valid_runtime_extras(%{
          "XAAS_A2A_DATA_DIR" => "/tmp/xaas-a2a",
          "CORS_ORIGINS" => "*,http://localhost:3000"
        })

      assert {:refused, report} = ProdEnvContract.validate(env, include_runtime_extras: true)
      assert Enum.any?(report.findings, &(&1.var == "XAAS_A2A_DATA_DIR" and &1.kind == :ephemeral_tmp_path))
      assert Enum.any?(report.findings, &(&1.var == "CORS_ORIGINS" and &1.kind == :wildcard_cors_origin))
      assert Enum.any?(report.findings, &(&1.var == "CORS_ORIGINS" and &1.kind == :insecure_cors_origin))
    end

    test "validate!/2 raises ProdEnvContract.Error without leaking secret values" do
      secret_cloak = b64_key(0xAB, 32)
      secret_admin = "super-sensitive-admin-pw-999"

      bad_env =
        valid_env(%{
          "CLOAK_KEY" => secret_cloak,
          "BLIND_INDEX_KEY" => secret_cloak,
          "ADMIN_PASSWORD" => "short"
        })

      err =
        assert_raise Error, fn ->
          ProdEnvContract.validate!(bad_env)
        end

      msg = Exception.message(err)
      assert msg =~ "PROD_ENV_CONTRACT REFUSED:"
      assert msg =~ "BLIND_INDEX_KEY"
      assert msg =~ "ADMIN_PASSWORD"
      refute msg =~ secret_cloak
      refute msg =~ secret_admin

      assert %{status: :ok} = ProdEnvContract.validate!(valid_env())
    end
  end
end
