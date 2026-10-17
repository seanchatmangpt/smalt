# scripts/bench/enclave_loop.exs — provision → data-plane read-your-write loop.
#
# Enclave harness: boots NOTHING itself. The wrapper lane owns substrate
# lifecycle (bench_boot-style private ports) and exports the SMALT_TEST_*_PORT
# envs (same names bench_boot sets, scripts/bench/lib.sh) before invoking:
#
#   MIX_ENV=test mix run --no-start scripts/bench/enclave_loop.exs
#
# Port env contract (defaults = the global substrate):
#   SMALT_TEST_ARM_PORT        (9443) — ARM front door, terraform + asserts
#   SMALT_TEST_EGRESS_PORT     (8443) — data plane (blob / secrets / cosmos)
#   SMALT_TEST_EVENT_HUBS_PORT (5673) — EH AMQP wire
#   SMALT_TEST_AMQP_PORT       (5672) — SB AMQP wire (unused here, reported)
#
# Phases, each with a typed verdict row on stdout (PASS / FAIL / SKIP-LOUD —
# a skip is always loud, never a silent pass):
#   1. PROVISION  — terraform -chdir test/terraform_fixture via scripts/smalt-tf
#                   (init → plan "3 to add" → apply), TF_CLI_CONFIG_FILE pinned
#                   to the offline provider mirror when it exists (same wiring
#                   scripts/tf_smoke.sh uses). provisioned=false on any failure.
#   2. ARM-ASSERT — GET rg / storage account / vault on the ARM front door;
#                   provisioningState must be "Succeeded".
#   3. DATA-PLANE — per-family, read-your-write at every hop:
#        blob    : ARM child route PUT container (9443, account-in-path on 8443)
#                  → blob PUT → blob GET → byte-exact read-your-write
#        secrets : feature-detect PUT /secrets/:name on 8443 (non-404-reserved
#                  answers) → GET → value equality
#        cosmos  : seed db/collection/doc on 8443 → query feed → doc id present
#        eh      : hub feature-detect via ARM eventhubs list (the fixture
#                  provisions none → this is normally SKIP-LOUD) → real AMQP 1.0
#                  wire send on 5673 (SASL ANONYMOUS, open/begin/attach/transfer)
#                  built on Smalt.Amqp.FrameCodec
#
# Rows are bench_emit-shaped JSON (lane, surface, op, verdict, n, ops_per_sec,
# p50/p95/p99, errors, machine) appended to ENCLAVE_RESULT_FILE (default
# docs/jira/v26.10.16/bench/c9-enclave-loop.jsonl) and echoed to stdout.

defmodule SmaltBench.EnclaveLoop do
  @lane System.get_env("ENCLAVE_LANE") || "c9"
  @result_file System.get_env("ENCLAVE_RESULT_FILE") ||
                 "docs/jira/v26.10.16/bench/c9-enclave-loop.jsonl"
  @fixture "test/terraform_fixture"
  @arm_port System.get_env("SMALT_TEST_ARM_PORT") || "9443"
  # Lane chain: SMALT_TEST_TLS_PORT (harness convention) -> SMALT_ARM_TLS_PORT
  # (exported by scripts/tf_enclave_loop.sh, lane TLS twin) -> canonical 9444.
  # Never silently aim the lane's terraform at the canonical twin.
  @tls_port System.get_env("SMALT_TEST_TLS_PORT") ||
              System.get_env("SMALT_ARM_TLS_PORT") || "9444"
  @egress_port System.get_env("SMALT_TEST_EGRESS_PORT") || "8443"
  @eh_port System.get_env("SMALT_TEST_EVENT_HUBS_PORT") || "5673"
  @amqp_port System.get_env("SMALT_TEST_AMQP_PORT") || "5672"

  @sub "00000000-0000-0000-0000-000000000000"
  @rg "rg-smalt-fixture"
  @acct "t5smaltfixturestore"
  @vault "kv-smalt-fixture"
  @api_version "2021-04-01"

  def run do
    File.mkdir_p!(Path.dirname(@result_file))
    meta_row()

    provisioned = provision_phase()

    arm_ok =
      if provisioned do
        arm_assert_phase()
      else
        skip_row("arm", "arm_assert", "provisioned=false — tf apply did not succeed")
        false
      end

    if arm_ok do
      blob_family()
      secrets_family()
      cosmos_family()
    else
      Enum.each(~w(blob secrets cosmos), fn fam ->
        skip_row(fam, fam, "provisioned=false — ARM assert did not pass")
      end)
    end

    eh_family(arm_ok)
    IO.puts("[enclave-loop] complete — rows in #{Path.absname(@result_file)}")
  end

  # -- row emission (bench_emit shape + verdict) ---------------------------------

  defp meta_row do
    emit(%{
      surface: "enclave-loop",
      op: "meta",
      verdict: "PASS",
      ports: %{
        arm: @arm_port,
        tls: @tls_port,
        egress: @egress_port,
        event_hubs: @eh_port,
        amqp: @amqp_port
      },
      errors: 0
    })
  end

  defp emit(rec) do
    base = %{
      lane: @lane,
      surface: "enclave-loop",
      op: "unknown",
      verdict: "PASS",
      n: 0,
      ops_per_sec: 0.0,
      p50_ms: 0.0,
      p95_ms: 0.0,
      p99_ms: 0.0,
      errors: 0,
      machine: machine_spec()
    }

    line = base |> Map.merge(rec) |> Jason.encode!()

    File.write!(@result_file, line <> "\n", [:append])
    IO.puts("[enclave-loop] " <> line)
  end

  defp skip_row(surface, op, reason) do
    emit(%{surface: surface, op: op, verdict: "SKIP-LOUD", reason: reason})
  end

  defp fail_row(surface, op, reason) do
    emit(%{surface: surface, op: op, verdict: "FAIL", reason: reason, errors: 1})
  end

  defp timed_ms(fun) do
    t0 = System.monotonic_time(:millisecond)
    out = fun.()
    {out, System.monotonic_time(:millisecond) - t0}
  end

  defp machine_spec do
    cpu =
      case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
        {name, 0} -> String.trim(name)
        _ -> "unknown"
      end

    ram_gb =
      case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
        {bytes, 0} ->
          case Integer.parse(String.trim(bytes)) do
            {n, _} -> div(n, 1024 * 1024 * 1024)
            :error -> 0
          end

        _ ->
          0
      end

    %{
      cpu: cpu,
      ram_gb: ram_gb,
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      darwin: elem(System.cmd("sw_vers", ["-productVersion"]), 0) |> String.trim()
    }
  end

  # -- HTTP helpers (:httpc, plaintext loopback) ----------------------------------

  defp http(method, port, path, body \\ "", headers \\ %{}) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    hdrs =
      Enum.map(Map.merge(%{"content-type" => "application/json"}, headers), fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    request = {
      url,
      hdrs,
      ~c"application/json",
      if(body == [], do: ~c"", else: String.to_charlist(body))
    }

    :httpc.request(method, request, [timeout: 15_000, connect_timeout: 10_000], [])
    |> case do
      {:ok, {{_httpv, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp json!(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      {:error, _} -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 1: PROVISION (terraform via scripts/smalt-tf)
  # ---------------------------------------------------------------------------
  defp provision_phase do
    fixture_abs = Path.absname(@fixture)

    cond do
      not File.dir?(fixture_abs) ->
        skip_row("provision", "tf_apply", "fixture dir missing: #{@fixture}")
        false

      System.find_executable("terraform") == nil ->
        skip_row("provision", "tf_apply", "terraform binary not on PATH")
        false

      true ->
        # Scratch-dir isolation (F9 fix, mirrors scripts/tf_enclave_loop.sh's
        # $WORK/fixture idiom): terraform state must never live in the shared
        # test/terraform_fixture — leftover state from a failed apply poisons
        # the next run (already-exists retry trips on the harness's own RG).
        # Copy *.tf (+ lock file + mirror rc) into a mkdtemp scratch and run
        # everything -chdir=there. The mirror rc embeds an ABSOLUTE path to the
        # fixture's provider-mirror (tf_mirror_env.sh), so it works from scratch
        # unmodified; the mirror is read-only from terraform's perspective.
        scratch =
          case System.cmd("mktemp", ["-d", "/tmp/enclave-tf.XXXXXX"], stderr_to_stdout: true) do
            {dir, 0} -> String.trim(dir)
            _ -> raise "mktemp -d failed for enclave tf scratch"
          end

        try do
          provision_phase_in(scratch, fixture_abs)
        after
          File.rm_rf!(scratch)
        end
    end
  end

  defp provision_phase_in(scratch, fixture_abs) do
    Enum.each(Path.wildcard(Path.join(fixture_abs, "*.tf")), fn tf ->
      File.copy!(tf, Path.join(scratch, Path.basename(tf)))
    end)

    # Pinned provider versions travel with the copy (avoids registry churn).
    lock = Path.join(fixture_abs, ".terraform.lock.hcl")

    if File.exists?(lock), do: File.copy!(lock, Path.join(scratch, ".terraform.lock.hcl"))

    # Offline provider mirror, same wiring tf_smoke/tf_plan_check use.
    mirror_rc = Path.join(fixture_abs, "provider-mirror.rc")

    use_mirror? =
      File.exists?(mirror_rc) and File.dir?(Path.join(fixture_abs, "provider-mirror"))

    if use_mirror?, do: File.copy!(mirror_rc, Path.join(scratch, "provider-mirror.rc"))

    # Mirror rc in scratch (a byte-copy of the fixture one; both embed the
    # absolute fixture mirror path, so either works — the copy keeps ALL terraform
    # inputs inside the scratch dir).
    scratch_rc = Path.join(scratch, "provider-mirror.rc")

    # Port-shifted authority routing, mirroring scripts/tf_plan_check.sh —
    # NOT scripts/smalt-tf (smalt-tf hardcodes 9443/9444 and would override
    # any inherited lane-port env, sending the lane's terraform at the
    # canonical substrate). Terraform is invoked directly with the full
    # lane-port env instead.
    tls = @tls_port
    ca = Path.absname(".smalt/tls/ca-cert.pem")

    base_env = [
      {"ARM_ENDPOINT", "http://localhost:#{@arm_port}"},
      {"ARM_RESOURCE_MANAGER_ENDPOINT", "http://localhost:#{@arm_port}"},
      {"ARM_RESOURCE_MANAGER_AUDIENCE", "https://management.azure.com"},
      {"ARM_METADATA_HOSTNAME", "localhost:#{tls}"},
      {"SSL_CERT_FILE", ca},
      {"AZURE_AUTHORITY_HOST", "https://localhost:#{tls}/"},
      {"AZAPI_ARM_ENDPOINT", "http://localhost:#{@arm_port}"},
      {"AZAPI_ARM_RESOURCE_MANAGER_ENDPOINT", "http://localhost:#{@arm_port}"},
      {"ARM_USE_MSI", "false"},
      {"ARM_CLIENT_ID", @sub},
      {"ARM_CLIENT_SECRET", "smalt-sovereign-mock-secret"},
      {"ARM_SUBSCRIPTION_ID", @sub},
      {"ARM_TENANT_ID", @sub},
      {"TF_IN_AUTOMATION", "1"}
    ]

    env =
      if use_mirror?, do: [{"TF_CLI_CONFIG_FILE", scratch_rc} | base_env], else: base_env

    mirror_state = if use_mirror?, do: "mirror", else: "registry"

    IO.puts(
      "[enclave-loop] tf routing: #{mirror_state}, terraform direct -> ARM #{@arm_port}, TLS twin #{tls}, scratch #{scratch}"
    )

    steps = [
      {"tf_init", ["init", "-input=false", "-no-color"]},
      {"tf_plan", ["plan", "-input=false", "-no-color"]},
      {"tf_apply", ["apply", "-auto-approve", "-no-color"]}
    ]

    Enum.reduce_while(steps, false, fn {op, args}, _ ->
      {result, ms} =
        timed_ms(fn ->
          System.cmd("terraform", args,
            cd: scratch,
            env: env,
            stderr_to_stdout: true
          )
        end)

      case result do
        {out, 0} ->
          # Plan gate mirrors tf_smoke.sh: exactly "3 to add" (rg+vault+acct).
          gate =
            if op == "tf_plan" do
              if out =~ "3 to add", do: :ok, else: {:fail, "plan did not report '3 to add'"}
            else
              :ok
            end

          case gate do
            :ok ->
              emit(%{op: op, verdict: "PASS", elapsed_ms: ms})
              {:cont, true}

            {:fail, why} ->
              fail_row("provision", op, why)
              {:halt, false}
          end

        {out, code} ->
          # `out` is another process's stderr — treat as untrusted bytes:
          # classification and tail extraction must be binary-safe.
          down? =
            out =~
              ~r/connection refused|econnrefused|dial tcp: lookup|no such host|i\/o timeout|Failed to query available provider|could not connect to registry/i

          cond do
            down? and op == "tf_init" and
                out =~
                  ~r/registry\.terraform\.io|Failed to query available provider|could not connect to registry/i ->
              skip_row("provision", op, "registry.terraform.io unreachable (exit #{code})")
              {:halt, false}

            down? ->
              skip_row(
                "provision",
                op,
                "substrate down — #{op} on localhost:#{@arm_port} refused (exit #{code})"
              )

              {:halt, false}

            true ->
              # azurerm's create-then-exists double-check ("already exists ...
              # needs to be imported") — residue from a prior half-applied run.
              # The wrapper (tf_enclave_loop.sh) retries destroy+re-plan+apply,
              # but that destroy is a NO-OP when the failed apply left terraform
              # state empty (witnessed). The harness instead PURGES the fixture
              # RG via the ARM REST front door (DELETE 202 cascades to vault +
              # storage account — witnessed 404s), then re-plans and re-applies.
              if op == "tf_apply" and out =~ "already exists" do
                IO.puts("[enclave-loop] apply hit already-exists; ARM purge + re-plan + re-apply")

                case purge_fixture_rg() do
                  :ok ->
                    run_tf(scratch, env, ["plan", "-input=false", "-no-color", "-out=tfplan"])

                    case run_tf(scratch, env, ["apply", "-auto-approve", "-no-color", "tfplan"]) do
                      {_, 0} ->
                        emit(%{
                          op: "tf_apply",
                          verdict: "PASS",
                          note: "already-exists retry",
                          errors: 0
                        })

                        {:cont, true}

                      {out2, code2} ->
                        fail_row(
                          "provision",
                          "tf_apply",
                          "retry exit #{code2}: #{truncate(tail4(out2))}"
                        )

                        {:halt, false}
                    end

                  {:error, why} ->
                    fail_row("provision", "tf_apply", "residue purge failed: #{why}")
                    {:halt, false}
                end
              else
                tail = tail4(out)

                fail_row("provision", op, "exit #{code}: #{truncate(tail)}")
                {:halt, false}
              end
          end
      end
    end)
  end

  # Scratch-local terraform runner (all state stays in the scratch dir).
  defp run_tf(scratch, env, args) do
    System.cmd("terraform", args, cd: scratch, env: env, stderr_to_stdout: true)
  end

  defp tail4(out) do
    out
    |> String.split("\n")
    |> Enum.take(-4)
    |> Enum.map(&String.slice(&1 || "", 0, 120))
    |> Enum.join(" | ")
  end

  # Residue purge for the already-exists retry: DELETE the fixture RG through
  # the ARM REST front door (202 Accepted; the emulator cascades the delete to
  # vault + storage account — witnessed 404s on all three after ~1s), polling
  # until the RG GET is 404.
  defp purge_fixture_rg do
    rg_path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}"

    with {:ok, token} <- arm_token() do
      headers = %{"authorization" => "Bearer #{token}"}

      case http(:delete, @arm_port, rg_path <> "?api-version=#{@api_version}", "", headers) do
        {:ok, s, _h, _b} when s in [200, 202, 204] ->
          poll_rg_gone(headers)

        {:ok, 404, _h, _b} ->
          :ok

        {:ok, s, _h, b} ->
          {:error, "RG DELETE HTTP #{s}: #{truncate(b)}"}

        {:error, why} ->
          {:error, "RG DELETE transport: #{why}"}
      end
    else
      {:error, why} -> {:error, why}
    end
  end

  defp poll_rg_gone(headers, tries \\ 20) do
    path = "/subscriptions/#{@sub}/resourceGroups/#{@rg}?api-version=#{@api_version}"

    case http_get_auth(path, headers) do
      {:ok, 404, _h, _b} ->
        :ok

      {:ok, _s, _h, _b} when tries > 0 ->
        Process.sleep(500)
        poll_rg_gone(headers, tries - 1)

      {:ok, s, _h, b} ->
        {:error, "RG still present after delete (GET #{s}: #{truncate(b)})"}

      {:error, why} ->
        {:error, "RG GET transport: #{why}"}
    end
  end

  # httpc rejects the 4-tuple (body-bearing) request form for GETs with a bare
  # body; authed GETs use the 2-tuple form with the auth header attached.
  defp http_get_auth(path, headers) do
    url = ~c"http://127.0.0.1:#{@arm_port}#{path}"

    hdrs =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    :httpc.request(:get, {url, hdrs}, [timeout: 15_000, connect_timeout: 10_000], [])
    |> case do
      {:ok, {{_httpv, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # STS client-credentials mint against the emulator (same shape the wrapper's
  # residue audit uses via curl).
  defp arm_token do
    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => @sub,
        "client_secret" => "smalt-sovereign-mock-secret",
        "scope" => "https://management.azure.com/.default"
      })

    case :httpc.request(
           :post,
           {~c"http://127.0.0.1:#{@arm_port}/#{@sub}/oauth2/v2.0/token", [],
            ~c"application/x-www-form-urlencoded", String.to_charlist(body)},
           [timeout: 10_000, connect_timeout: 10_000],
           []
         ) do
      {:ok, {{_, 200, _}, _h, resp_body}} ->
        case json!(to_string(resp_body))["access_token"] do
          nil -> {:error, "STS token response carried no access_token"}
          tok -> {:ok, tok}
        end

      {:ok, {{_, s, _}, _h, resp_body}} ->
        {:error, "STS HTTP #{s}: #{truncate(to_string(resp_body))}"}

      {:error, why} ->
        {:error, "STS transport: #{inspect(why)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2: ARM-ASSERT (9443)
  # ---------------------------------------------------------------------------
  defp arm_assert_phase do
    checks = [
      {"rg", "/subscriptions/#{@sub}/resourceGroups/#{@rg}"},
      {"storage_account",
       "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/#{@acct}"},
      {"vault",
       "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/#{@vault}"}
    ]

    Enum.all?(checks, fn {name, path} ->
      path = path <> "?api-version=#{@api_version}"

      case http(:get, @arm_port, path) do
        {:ok, 200, _h, body} ->
          state = json!(body) |> get_in(["properties", "provisioningState"])

          if state == "Succeeded" do
            emit(%{surface: "arm", op: "arm_assert_#{name}", verdict: "PASS", errors: 0})
            true
          else
            fail_row(
              "arm",
              "arm_assert_#{name}",
              "provisioningState=#{inspect(state)} (want Succeeded)"
            )

            false
          end

        {:ok, status, _h, _body} ->
          fail_row("arm", "arm_assert_#{name}", "HTTP #{status}")
          false

        {:error, why} ->
          fail_row("arm", "arm_assert_#{name}", "transport: #{why}")
          false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Phase 3: DATA-PLANE families (8443), read-your-write at each hop
  # ---------------------------------------------------------------------------
  # Blob: container via the ARM child route (9443), data via account-in-path
  # on 8443 — the provision→data seam this harness exists to exercise.
  defp blob_family do
    run_id = System.system_time(:millisecond)
    container = "enclave-#{run_id}"
    blob = "rw-probe.bin"
    body = :binary.copy("enclave-read-your-write-", 64)

    # Hop 1: create container through the ARM child route.
    arm_container_path =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/#{@acct}/blobServices/default/containers/#{container}?api-version=#{@api_version}"

    case http(
           :put,
           @arm_port,
           arm_container_path,
           Jason.encode!(%{"properties" => %{"publicAccess" => "None"}})
         ) do
      {:ok, s, _h, _b} when s in 200..201 ->
        emit(%{surface: "blob", op: "arm_create_container", verdict: "PASS", errors: 0})

        # Hop 2: data-plane blob PUT on 8443 (account-in-path).
        case http(:put, @egress_port, "/#{@acct}/#{container}/#{blob}", body, %{
               "x-ms-blob-type" => "BlockBlob"
             }) do
          {:ok, s2, _h2, _b2} when s2 in 200..201 ->
            emit(%{surface: "blob", op: "blob_put", verdict: "PASS", errors: 0})

            # Hop 3: read-your-write — byte-exact GET.
            case http(:get, @egress_port, "/#{@acct}/#{container}/#{blob}") do
              {:ok, 200, _h3, got} ->
                if got == body do
                  emit(%{
                    surface: "blob",
                    op: "blob_get_read_your_write",
                    verdict: "PASS",
                    n: 1,
                    errors: 0
                  })
                else
                  fail_row(
                    "blob",
                    "blob_get_read_your_write",
                    "byte mismatch (#{byte_size(got)} vs #{byte_size(body)} bytes)"
                  )
                end

              {:ok, s3, _h3, _b3} ->
                fail_row("blob", "blob_get_read_your_write", "HTTP #{s3}")

              {:error, why} ->
                fail_row("blob", "blob_get_read_your_write", "transport: #{why}")
            end

          {:ok, s2, _h2, b2} ->
            fail_row("blob", "blob_put", "HTTP #{s2}: #{truncate(b2)}")

          {:error, why} ->
            fail_row("blob", "blob_put", "transport: #{why}")
        end

      {:ok, s, _h, b} ->
        fail_row("blob", "arm_create_container", "HTTP #{s}: #{truncate(b)} (ARM child route)")

      {:error, why} ->
        fail_row("blob", "arm_create_container", "transport: #{why}")
    end
  end

  # Secrets: feature-detect — the /secrets plane must answer non-404; a 404
  # (surface reserved/not provisioned) is a SKIP-LOUD, never a fake pass.
  defp secrets_family do
    name = "enclave-secret-#{System.system_time(:millisecond)}"
    value = "s3cr3t-read-your-write-#{run_tag()}"

    case http(:put, @egress_port, "/secrets/#{name}", Jason.encode!(%{"value" => value})) do
      {:ok, 404, _h, _b} ->
        skip_row("secrets", "secret_put", "/secrets answered 404 — surface not provisioned")

      {:ok, s, _h, _b} when s in 200..201 ->
        emit(%{surface: "secrets", op: "secret_put", verdict: "PASS", errors: 0})

        case http(:get, @egress_port, "/secrets/#{name}") do
          {:ok, 200, _h, body} ->
            got = json!(body)["value"]

            if got == value do
              emit(%{
                surface: "secrets",
                op: "secret_get_read_your_write",
                verdict: "PASS",
                n: 1,
                errors: 0
              })
            else
              fail_row(
                "secrets",
                "secret_get_read_your_write",
                "value mismatch: #{truncate(got || "")}"
              )
            end

          {:ok, s2, _h, b2} ->
            fail_row("secrets", "secret_get_read_your_write", "HTTP #{s2}: #{truncate(b2)}")

          {:error, why} ->
            fail_row("secrets", "secret_get_read_your_write", "transport: #{why}")
        end

      {:ok, s, _h, b} ->
        fail_row("secrets", "secret_put", "HTTP #{s}: #{truncate(b)}")

      {:error, why} ->
        fail_row("secrets", "secret_put", "transport: #{why}")
    end
  end

  # Cosmos: seed db/collection/doc on the 8443 data plane, then read-your-write
  # through the query feed. A collection surface that refuses to seed → SKIP-LOUD.
  defp cosmos_family do
    tag = run_tag()
    db = "enclavedb#{tag}"
    coll = "items"

    with {:db, {:ok, s1, _h1, _b1}} when s1 in 200..201 <-
           {:db, http(:put, @egress_port, "/dbs/#{db}", Jason.encode!(%{"id" => db}))},
         {:coll, {:ok, s2, _h2, _b2}} when s2 in 200..201 <-
           {:coll,
            http(:put, @egress_port, "/dbs/#{db}/colls/#{coll}", Jason.encode!(%{"id" => coll}))},
         {:doc, {:ok, s3, _h3, _b3}} when s3 in 200..201 <-
           {:doc,
            http(
              :post,
              @egress_port,
              "/dbs/#{db}/colls/#{coll}/docs",
              Jason.encode!(%{"id" => "enclave-doc-1", "mark" => "enclave-#{tag}"})
            )} do
      emit(%{surface: "cosmos", op: "seed_db_coll_doc", verdict: "PASS", errors: 0})

      # Query feed read-your-write.
      q = %{
        "query" => "SELECT * FROM c WHERE c.mark = @mark",
        "parameters" => [%{"name" => "@mark", "value" => "enclave-#{tag}"}]
      }

      case http(:post, @egress_port, "/dbs/#{db}/colls/#{coll}/docs", Jason.encode!(q), %{
             "x-ms-documentdb-query" => "true",
             "x-ms-documentdb-isquery" => "true"
           }) do
        {:ok, 200, _h, body} ->
          ids = (json!(body)["Documents"] || []) |> Enum.map(& &1["id"])

          if "enclave-doc-1" in ids do
            emit(%{
              surface: "cosmos",
              op: "query_feed_read_your_write",
              verdict: "PASS",
              n: 1,
              errors: 0
            })
          else
            fail_row(
              "cosmos",
              "query_feed_read_your_write",
              "doc id absent from query feed: #{truncate(Jason.encode!(ids))}"
            )
          end

        {:ok, s4, _h, b4} ->
          fail_row("cosmos", "query_feed_read_your_write", "HTTP #{s4}: #{truncate(b4)}")

        {:error, why} ->
          fail_row("cosmos", "query_feed_read_your_write", "transport: #{why}")
      end
    else
      {:db, {:ok, s, _h, b}} ->
        fail_row("cosmos", "seed_db", "HTTP #{s}: #{truncate(b)}")

      {:coll, {:ok, s, _h, b}} ->
        skip_row(
          "cosmos",
          "seed_collection",
          "HTTP #{s}: #{truncate(b)} — collection surface not answering"
        )

      {:coll, {:error, why}} ->
        skip_row("cosmos", "seed_collection", "transport: #{why}")

      {:doc, {:ok, s, _h, b}} ->
        fail_row("cosmos", "seed_doc", "HTTP #{s}: #{truncate(b)}")

      {:db, {:error, why}} ->
        fail_row("cosmos", "seed_db", "transport: #{why}")

      {:doc, {:error, why}} ->
        fail_row("cosmos", "seed_doc", "transport: #{why}")
    end
  end

  # Event Hubs: fixture provisions no hub → normally SKIP-LOUD. When a hub IS
  # visible through ARM, the send is a REAL AMQP 1.0 wire transfer on 5673
  # (SASL ANONYMOUS per the wire pinion) built on Smalt.Amqp.FrameCodec.
  defp eh_family(arm_ok) do
    hub_path =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.EventHub/namespaces?api-version=#{@api_version}"

    hubs =
      if arm_ok do
        case http(:get, @arm_port, hub_path) do
          {:ok, 200, _h, body} -> json!(body)["value"] || []
          _ -> []
        end
      else
        []
      end

    case hubs do
      [] ->
        skip_row(
          "eh",
          "eh_wire_send",
          "no EventHub namespace/hub provisioned by fixture (ARM list empty)"
        )

      [%{"name" => ns} | _] = _hubs ->
        hub_list_path =
          "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.EventHub/namespaces/#{ns}/eventhubs?api-version=#{@api_version}"

        case http(:get, @arm_port, hub_list_path) do
          {:ok, 200, _h, body} ->
            case json!(body)["value"] || [] do
              [] ->
                skip_row("eh", "eh_wire_send", "namespace #{ns} has no eventhubs")

              [%{"name" => hub} | _] ->
                eh_wire_send(ns, hub)
            end

          {:ok, s, _h, b} ->
            skip_row("eh", "eh_wire_send", "hub list HTTP #{s}: #{truncate(b)}")

          {:error, why} ->
            skip_row("eh", "eh_wire_send", "transport: #{why}")
        end

      _ ->
        skip_row("eh", "eh_wire_send", "unexpected ARM list shape")
    end
  end

  # Real wire send: proto header → SASL ANONYMOUS → open → begin → attach →
  # transfer → detach → close. Any step failure is a typed FAIL row.
  defp eh_wire_send(ns, hub) do
    case :gen_tcp.connect(
           ~c"127.0.0.1",
           String.to_integer(@eh_port),
           [:binary, active: false],
           10_000
         ) do
      {:ok, sock} ->
        payload =
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:transfer, %{handle: 0, delivery_id: 1, delivery_tag: "eh-1", more: false},
             {:sections, [{:body_data, "enclave-read-your-write-" <> run_tag()}]}}
          )
          |> IO.iodata_to_binary()

        result =
          try do
            amqp_wire_roundtrip(sock, "amqphub:#{ns}:#{hub}", payload)
          rescue
            e -> {:error, Exception.message(e)}
          after
            :gen_tcp.close(sock)
          end

        case result do
          {:ok, ms} ->
            emit(%{
              surface: "eh",
              op: "eh_wire_send",
              verdict: "PASS",
              n: 1,
              elapsed_ms: ms,
              errors: 0
            })

          {:error, why} ->
            fail_row("eh", "eh_wire_send", "AMQP wire: #{why}")
        end

      {:error, why} ->
        fail_row("eh", "eh_wire_send", "tcp connect 127.0.0.1:#{@eh_port}: #{inspect(why)}")
    end
  end

  defp amqp_wire_roundtrip(sock, target_addr, transfer_payload) do
    t0 = System.monotonic_time(:millisecond)
    :ok = :gen_tcp.send(sock, "AMQP\u0000\u0001\u0000\u0000")

    # SASL layer when the server answers with AMQP\x03... (sasl frame type).
    {hdr, rest} = read_proto_header(sock)

    if sasl?(hdr) do
      :ok = :gen_tcp.send(sock, "AMQP\u0000\u0001\u0000\u0000")

      :ok =
        :gen_tcp.send(
          sock,
          IO.iodata_to_binary(
            Smalt.Amqp.FrameCodec.encode_frame(
              :sasl,
              0,
              {:sasl_init, %{mechanism: "ANONYMOUS", initial_response: ""}}
            )
          )
        )

      wait_sasl_outcome(sock, rest)
      :ok = :gen_tcp.send(sock, "AMQP\u0000\u0001\u0000\u0000")
    else
      pushback(rest)
      _ = pushback(rest)
    end

    :ok =
      :gen_tcp.send(
        sock,
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:open,
             %{
               container_id: "smalt-enclave-loop",
               hostname: "localhost",
               max_frame_size: 65_536,
               channel_max: 0
             }}
          )
        )
      )

    :ok =
      :gen_tcp.send(
        sock,
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}
          )
        )
      )

    :ok =
      :gen_tcp.send(
        sock,
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:attach,
             %{
               name: "enclave-sender",
               handle: 0,
               role: false,
               snd_settle_mode: 0,
               source: %{address: "enclave-sender"},
               target: %{address: target_addr}
             }}
          )
        )
      )

    # Wait for the server's attach + flow before transferring.
    wait_for(sock, rest, ["attach", "flow"], 10_000)

    :ok = :gen_tcp.send(sock, transfer_payload)

    # Server should answer with a disposition (settled outcome) for the transfer.
    case wait_for(sock, "", ["disposition"], 10_000) do
      {:ok, _frames} ->
        # Politely detach + close; responses after this don't matter.
        :ok =
          :gen_tcp.send(
            sock,
            IO.iodata_to_binary(
              Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:detach, %{handle: 0, closed: true}})
            )
          )

        :ok =
          :gen_tcp.send(
            sock,
            IO.iodata_to_binary(
              Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:close, %{error: nil}})
            )
          )

        {:ok, System.monotonic_time(:millisecond) - t0}

      {:error, why} ->
        {:error, "no disposition for transfer: #{why}"}
    end
  end

  defp sasl?(<<_::16, 0x03, _::16>>), do: true
  defp sasl?(_), do: false

  # Reads the 8-byte AMQP proto header from the socket (buffering whatever
  # else arrives with it).
  defp read_proto_header(sock) do
    case :gen_tcp.recv(sock, 8, 10_000) do
      {:ok, <<"AMQP", _::size(8), _::size(8), _::size(16)>> = hdr} -> {hdr, ""}
      {:ok, other} -> {"", other}
      {:error, why} -> throw({:wire, "proto header: #{inspect(why)}"})
    end
  end

  # Leftover bytes from an earlier read that belong to subsequent frames.
  defp pushback(_buf), do: :ok

  defp wait_sasl_outcome(sock, buf) do
    deadline = System.monotonic_time(:millisecond) + 10_000

    do_wait_sasl(sock, buf, deadline)
  end

  defp do_wait_sasl(sock, buf, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      throw({:wire, "sasl outcome timeout"})
    end

    case next_frame(sock, buf) do
      {:ok, frame, rest} ->
        case frame_performative(frame) do
          :sasl_outcome ->
            :ok

          _ ->
            do_wait_sasl(sock, rest, deadline)
        end

      {:more, need} ->
        {:ok, chunk} = :gen_tcp.recv(sock, max(need - byte_size(buf), 1), 10_000)
        do_wait_sasl(sock, buf <> chunk, deadline)

      {:error, why} ->
        throw({:wire, "sasl: #{why}"})
    end
  end

  # Waits until a frame whose performative is in `names` has been seen (all
  # frames drained, not just the first match — server may batch attach+flow).
  defp wait_for(sock, buf, names, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(sock, buf, names, deadline, [])
  end

  defp do_wait(sock, buf, names, deadline, _seen) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, "timeout waiting for #{inspect(names)}"}

      names == [] ->
        {:ok, :seen_all}

      true ->
        case next_frame(sock, buf) do
          {:ok, frame, rest} ->
            perf = frame_performative(frame)

            cond do
              perf == :close ->
                {:error, "server sent close while waiting for #{inspect(names)}"}

              perf in names ->
                do_wait(sock, rest, names -- [perf], deadline, [])

              true ->
                do_wait(sock, rest, names, deadline, [])
            end

          {:more, need} ->
            with {:ok, chunk} <- :gen_tcp.recv(sock, max(need - byte_size(buf), 1), 10_000) do
              do_wait(sock, buf <> chunk, names, deadline, [])
            else
              {:error, why} -> {:error, "recv: #{inspect(why)}"}
            end

          {:error, why} ->
            {:error, why}
        end
    end
  end

  defp next_frame(_sock, buf) do
    case Smalt.Amqp.FrameCodec.decode_frame(buf) do
      {:ok, frame} -> {:ok, frame, ""}
      {:ok, frame, rest} -> {:ok, frame, rest}
      {:more, need} -> {:more, need}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp frame_performative(%{performative: %{__struct__: s}}),
    do: s |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()

  defp frame_performative(%{performative: %{kind: k}}) when is_atom(k), do: k

  defp frame_performative(%{performative: m}) when is_map(m) do
    case Map.get(m, :performative) || Map.get(m, :name) || Map.get(m, :type) do
      v when is_atom(v) -> v
      _ -> :unknown
    end
  end

  defp frame_performative(_), do: :unknown

  defp run_tag, do: Integer.to_string(System.system_time(:millisecond))

  # Binary-safe truncation: the input is other processes' stderr (untrusted
  # bytes — may be invalid UTF-8 or not a binary at all). Never binary_part;
  # grapheme-safe slice for valid UTF-8, byte-count stub otherwise.
  defp truncate(v) when is_binary(v) do
    if String.valid?(v) do
      String.slice(v, 0, 160) || ""
    else
      "invalid-utf8(#{byte_size(v)}B)"
    end
  end

  defp truncate(v), do: v |> to_string() |> truncate()
end

SmaltBench.EnclaveLoop.run()
