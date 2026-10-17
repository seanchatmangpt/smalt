# 22-native — Sovereign Enclave NATIVE lifecycle surface (v26.10.16)
#
# Wires the landed native lifecycle entrypoints (no `Smalt.Enclave.Lifecycle`
# module and no `mix smalt.doctor` task have landed; adjusted to reality):
#
#   test/terraform_fixture HCL
#     --Smalt.Enclave.Hcl.parse/1-->  resource terms
#     --Smalt.Enclave.Engine.apply/2 (in-process ARM router, no terraform)-->
#     outcomes -> state JSON (tmp/native-enclave-state.json)
#     --Smalt.Enclave.State.plan/destroy-->
#     zero-drift / cascade-destroy / residue audit
#
# Boot pattern copied from test/enclave-testbed/run.sh: ONE dedicated beam on
# private ports 29445-29449 (the testbed owns 29440-29444), private lock,
# `mix run --no-start` with ENCLAVE pinning BEFORE app boot, lock fd closed
# (`9>&-`) per the fan-out law. Never touches the shared 9443/8443 substrate.
#
# Recipe-name disclosure: `test-wire` and `doctor` already exist in the root
# Justfile (T2 wire tier / doctor.py human mode). just aborts on duplicate
# recipe names across imports, so this module lands the spec's variants as
# `cleanroom` (tf_cleanroom.sh ladder) and `doctor-json` (doctor.py --json
# receipt); the root recipes are untouched.

NATIVE_STATE := "tmp/native-enclave-state.json"

# Shared native-lifecycle runner. NATIVE_MODE: test | apply | destroy | audit | verify.
[private]
@_native-lifecycle MODE:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cd "$ROOT"
    # macOS mktemp requires TRAILING X's in the template — a 'XXXXXX.exs'
    # suffix makes it fail with a confusing 'File exists'. Generate a tmpdir
    # and put the .exs extension on the file inside it.
    EXSDIR="$(mktemp -d /tmp/native-lifecycle.XXXXXXXX)"
    EXS="$EXSDIR/lifecycle.exs"
    trap 'rm -rf "$EXSDIR"' EXIT  # SHIM-COURT-free: single trap covers $EXS (inside $EXSDIR); a second trap would REPLACE this one and leak /tmp/native-lifecycle.* dirs
    export NATIVE_MODE="{{MODE}}"
    export NATIVE_FIXTURE="${NATIVE_FIXTURE:-test/terraform_fixture}"
    export NATIVE_STATE="${NATIVE_STATE:-{{NATIVE_STATE}}}"
    mkdir -p "$(dirname "$NATIVE_STATE")"
    # Lock fd CLOSED on spawn (fan-out law 4): the beam must not inherit the
    # flock, or it holds /tmp/smalt-substrate-native.lock forever.
    exec 9>"/tmp/smalt-substrate-native.lock"
    flock -w 600 -x 9 || { echo "[native] lock not acquired in 600s"; exit 3; }
    cat >"$EXS" <<'ELIXIR'
    mode = System.fetch_env!("NATIVE_MODE")
    fixture = System.fetch_env!("NATIVE_FIXTURE")
    state_path = System.fetch_env!("NATIVE_STATE")

    # Pin the private port set BEFORE app boot (testbed pattern), then boot the
    # application exactly once: full Smalt.Application (Store, broker, endpoints).
    Enum.each(
      [
        {:amqp_port, 29445},
        {:event_hubs_port, 29446},
        {:arm_port, 29447},
        {:egress_port, 29448},
        {:arm_tls_port, 29449},
        # mcp_port 9545 is held by the shared substrate — pin it too (witnessed
        # eaddrinuse: Bandit listener start failed with the default 9545).
        {:mcp_port, 29450}
      ],
      fn {k, v} -> Application.put_env(:smalt, k, v) end
    )

    # The native lifecycle is a test/dev surface: :enforce-mode bearer auth
    # would 401 MissingBearerToken the engine's in-process router dispatches
    # (witnessed); tests run :anonymous (config/test.exs) — same here.
    Application.put_env(:smalt, :auth_mode, :anonymous)

    {:ok, _} = Application.ensure_all_started(:smalt)

    {:ok, doc} = Smalt.Enclave.Hcl.parse(Path.join(fixture, "main.tf"))

    # Engine labels are "type.name" — terraform fixtures reuse the bare name
    # across types (witnessed {:duplicate_label, "smalt_fixture"} with bare
    # names), and Hcl refs are ALREADY {:ref, "type.name", attr}, which is
    # exactly the Engine's ref-target key. No rewriting needed.
    terms =
      Enum.map(doc.resources, fn r ->
        %{type: r.type, label: r.type <> "." <> r.name, attrs: r.attrs}
      end)

    # Engine outcomes carry the HCL face (:type = azurerm_*); State.plan /
    # State.destroy key the store by the ARM face (witnessed: plan returned
    # {:type, ...} drift and {:missing, rg} when fed azurerm types — the RG
    # lives in its own table keyed by the ARM type). Normalize to arm_type.
    arm_terms = fn outcomes ->
      Map.new(outcomes, fn o ->
        {o.label, %{label: o.label, id: o.id, type: o.arm_type, status: o.status}}
      end)
    end

    report_residue = fn residue ->
      nonempty = Enum.filter(residue, fn {_t, ks} -> ks != [] end)

      if nonempty == [] do
        IO.puts("[native] residue clean across #{map_size(residue)} tables")
      else
        IO.puts("[native] RESIDUE NONZERO: #{inspect(nonempty, limit: 20)}")
        exit({:shutdown, 1})
      end
    end

    # Shared residue printer + fail-closed gate used by destroy/audit/test/verify.
    case mode do
      "apply" ->
        {:ok, outcomes} = Smalt.Enclave.Engine.apply(terms)
        by_label = arm_terms.(outcomes)
        File.write!(state_path, Jason.encode!(by_label, pretty: true) <>"\n")
        IO.puts("[native] apply: #{length(outcomes)} resources provisioned -> #{state_path}")

      "destroy" ->
        # The store is in-memory ETS per beam — a state file from a PRIOR
        # `just apply` beam cannot be deleted from this beam (witnessed:
        # DELETE -> 404). Honest destroy: re-apply in this beam, PARITY-CHECK
        # the recorded ids (deterministic ids make this exact), then destroy.
        # No state file = loud skip, never a fake pass.
        unless File.exists?(state_path) do
          IO.puts("[SKIP-LOUD] destroy: no applied state at #{state_path} — run `just apply` first")
          exit({:shutdown, 3})
        end

        {:ok, bin} = File.read(state_path)
        prior = Jason.decode!(bin)
        {:ok, outcomes} = Smalt.Enclave.Engine.apply(terms)
        by_label = arm_terms.(outcomes)

        mismatch =
          Enum.find(by_label, fn {label, t} ->
            (prior[label] && prior[label]["id"]) != t.id
          end)

        if mismatch do
          {label, t} = mismatch
          IO.puts("[native] destroy: state-file parity FAILED at #{label}: recorded=#{inspect(prior[label] && prior[label]["id"])} applied=#{inspect(t.id)}")
          exit({:shutdown, 1})
        end

        %{deleted: deleted, residue: residue} = Smalt.Enclave.State.destroy(by_label)
        File.rm(state_path)
        IO.puts("[native] destroy: parity ok, #{length(deleted)} resources deleted (verified 404 each)")
        report_residue.(residue)

      "audit" ->
        {:ok, outcomes} = Smalt.Enclave.Engine.apply(terms)
        by_label = arm_terms.(outcomes)
        %{deleted: deleted, residue: residue} = Smalt.Enclave.State.destroy(by_label)
        IO.puts("[native] audit: applied #{length(outcomes)}, destroyed #{length(deleted)}")
        report_residue.(residue)

      "test" ->
        {:ok, outcomes} = Smalt.Enclave.Engine.apply(terms)
        by_label = arm_terms.(outcomes)
        drift = Smalt.Enclave.State.plan(by_label)

        if drift != [] do
          IO.puts("[native] DRIFT after apply: #{inspect(drift, limit: 10)}")
          exit({:shutdown, 1})
        end

        %{deleted: deleted, residue: residue} = Smalt.Enclave.State.destroy(by_label)
        IO.puts("[native] test: apply #{length(outcomes)} ok, plan zero-drift, destroy #{length(deleted)} ok")
        report_residue.(residue)

      "verify" ->
        # Data-plane read-your-write parity audit WITHOUT terraform: the state
        # file (written by `just apply`) is the "already-applied fixture state"
        # receipt. Bash wrapper SKIP-LOUDs (exit 3) when it is missing/empty.
        {:ok, bin} = File.read(state_path)

        if String.trim(bin) == "" do
          IO.puts("[SKIP-LOUD] verify: state file #{state_path} is empty — run `just apply` first")
          exit({:shutdown, 3})
        end

        prior = Jason.decode!(bin)
        {:ok, outcomes} = Smalt.Enclave.Engine.apply(terms)
        by_label = arm_terms.(outcomes)

        # Parity: the freshly-applied native engine outcomes must equal the
        # recorded state (same labels, same ids). A mismatch means the store
        # the data-plane phase reads is NOT the already-applied fixture state.
        state_mismatch =
          Enum.find(outcomes, fn o ->
            prior[o.label |> to_string()]["id"] != o.id
          end)

        if state_mismatch do
          IO.puts(
            "[native] verify: state-file parity FAILED at #{state_mismatch.label}: " <>
              "recorded=#{inspect(prior[to_string(state_mismatch.label)]["id"])} applied=#{inspect(state_mismatch.id)}"
          )

          exit({:shutdown, 1})
        end

        drift = Smalt.Enclave.State.plan(by_label)

        if drift != [] do
          IO.puts("[native] verify: DRIFT vs store: #{inspect(drift, limit: 10)}")
          exit({:shutdown, 1})
        end

        IO.puts("[native] verify: state-file parity ok (#{length(outcomes)} resources), zero drift")

        defmodule Native.Verify do
          @ports %{arm: 29447, egress: 29448}
          @sub "00000000-0000-0000-0000-000000000000"
          @rg "rg-smalt-fixture"
          @acct "t5smaltfixturestore"
          @api_version "2021-04-01"
          @tag System.system_time(:millisecond)

          def run do
            :persistent_term.put({:nv, :token}, mint())

            results = [
              blob_family(),
              secrets_family(),
              cosmos_family()
            ]

            fails = Enum.count(results, &(&1 == :fail))

            if fails > 0 do
              IO.puts("[native] verify data-plane: #{fails} family(ies) FAILED")
              exit({:shutdown, 1})
            end

            IO.puts("[native] verify data-plane: all families read-your-write PASS")
          end

          defp blob_family do
            container = "verify-#{@tag}"
            blob = "rw-probe.bin"
            body = :binary.copy("native-verify-read-your-write-", 64)

            # Container is created through the REAL blob REST surface on the
            # data plane (Put Container, restype=container). The ARM child
            # route registers the container as a generic ARM resource and does
            # NOT populate :smalt_blob_containers (witnessed: ContainerNotFound
            # on the follow-up Put Blob), so the cross-plane hop is the honest
            # read-your-write seam here.
            with {:put, {:ok, s1, _, _}} when s1 in 200..201 <-
                   {:put,
                    http(:put, @ports.egress, "/#{@acct}/#{container}?restype=container", "", %{"x-ms-version" => "2021-12-02"})},
                 {:blob, {:ok, s2, _, _}} when s2 in 200..201 <-
                   {:blob, http(:put, @ports.egress, "/#{@acct}/#{container}/#{blob}", body, %{"x-ms-blob-type" => "BlockBlob", "x-ms-version" => "2021-12-02"})},
                 {:get, {:ok, 200, _, got}} <-
                 {:get, http(:get, @ports.egress, "/#{@acct}/#{container}/#{blob}", "", %{"x-ms-version" => "2021-12-02"})} do
              if got == body do
                IO.puts("[native] verify blob: arm container + blob PUT + byte-exact GET PASS")
                :ok
              else
                IO.puts("[native] verify blob: byte mismatch (#{byte_size(got)} vs #{byte_size(body)})")
                :fail
              end
            else
              {:put, {:ok, s, _, b}} -> fail("blob", "arm_create_container HTTP #{s}: #{clip(b)}")
              {:blob, {:ok, s, _, b}} -> fail("blob", "blob_put HTTP #{s}: #{clip(b)}")
              {:get, {:ok, s, _, b}} -> fail("blob", "blob_get HTTP #{s}: #{clip(b)}")
              {:put, {:error, why}} -> fail("blob", "arm_create_container transport: #{inspect(why)}")
              {:blob, {:error, why}} -> fail("blob", "blob_put transport: #{inspect(why)}")
              {:get, {:error, why}} -> fail("blob", "blob_get transport: #{inspect(why)}")
            end
          end

          defp secrets_family do
            name = "verify-secret-#{@tag}"
            value = "s3cr3t-verify-#{@tag}"

            case http(:put, @ports.egress, "/secrets/#{name}", Jason.encode!(%{"value" => value})) do
              {:ok, 404, _, _} ->
                IO.puts("[native] verify secrets: /secrets answered 404 — surface not provisioned (SKIP-LOUD)")
                :ok

              {:ok, s, _, _} when s in 200..201 ->
                case http(:get, @ports.egress, "/secrets/#{name}") do
                  {:ok, 200, _, body} ->
                    if json(body)["value"] == value do
                      IO.puts("[native] verify secrets: PUT + GET read-your-write PASS")
                      :ok
                    else
                      IO.puts("[native] verify secrets: value mismatch")
                      :fail
                    end

                  {:ok, s2, _, b2} ->
                    fail("secrets", "secret_get HTTP #{s2}: #{clip(b2)}")

                  {:error, why} ->
                    fail("secrets", "secret_get transport: #{inspect(why)}")
                end

              {:ok, s, _, b} ->
                fail("secrets", "secret_put HTTP #{s}: #{clip(b)}")

              {:error, why} ->
                fail("secrets", "secret_put transport: #{inspect(why)}")
            end
          end

          defp cosmos_family do
            db = "verifydb#{@tag}"
            coll = "items"
            doc_id = "verify-doc-1"

            # Cosmos wire uses the real Azure verbs: create db/coll/doc are
            # POSTs (PUT /dbs/:db is a reserved-namespace refusal, witnessed).
            with {:ok, s1, _, _} when s1 in 200..201 <-
                   http(:post, @ports.egress, "/dbs", Jason.encode!(%{"id" => db}), %{"x-ms-version" => "2021-04-01"}),
                 {:ok, s2, _, _} when s2 in 200..201 <-
                   http(:post, @ports.egress, "/dbs/#{db}/colls", Jason.encode!(%{"id" => coll}), %{"x-ms-version" => "2021-04-01"}),
                 {:ok, s3, _, _} when s3 in 200..201 <-
                   http(:post, @ports.egress, "/dbs/#{db}/colls/#{coll}/docs", Jason.encode!(%{"id" => doc_id, "mark" => "verify-#{@tag}"}), %{"x-ms-version" => "2021-04-01"}) do
              # Only `SELECT * FROM alias` is whitelisted by the cosmos SQL
              # gate (GAP(cosmos-sql-translator-absent)); parameterized WHERE
              # answers a typed 400 SyntaxError. The db is fresh per run, so
              # the full-scan query is a real read-your-write assertion.
              q = %{"query" => "SELECT * FROM c"}

              # Query POST is detected by content-type application/query+json
              # (egress_router.ex query_post?/1) — the x-ms-documentdb-* headers
              # alone are NOT the wire (witnessed: the POST created a doc).
              case http(:post, @ports.egress, "/dbs/#{db}/colls/#{coll}/docs", Jason.encode!(q), %{
                     "content-type" => "application/query+json",
                     "x-ms-version" => "2021-04-01"
                   }) do
                {:ok, 200, _, body} ->
                  if doc_id in Enum.map(json(body)["Documents"] || [], & &1["id"]) do
                    IO.puts("[native] verify cosmos: seed + query feed read-your-write PASS")
                    :ok
                  else
                    IO.puts("[native] verify cosmos: doc absent from query feed")
                    :fail
                  end

                {:ok, s4, _, b4} ->
                  fail("cosmos", "query HTTP #{s4}: #{clip(b4)}")

                {:error, why} ->
                  fail("cosmos", "query transport: #{inspect(why)}")
              end
            else
              {:ok, s, _, b} -> fail("cosmos", "seed HTTP #{s}: #{clip(b)}")
              {:error, why} -> fail("cosmos", "seed transport: #{inspect(why)}")
            end
          end

          # :enforce substrate refuses tokenless calls — mint an STS bearer
          # the same way the console harness (enclave-loop.mjs) does.
          defp mint do
            body =
              URI.encode_query(%{
                "grant_type" => "client_credentials",
                "client_id" => "native-verify",
                "client_secret" => "native-verify-secret",
                "scope" => "https://management.azure.com/.default"
              })

            case http(:post, @ports.arm, "/dev/oauth2/v2.0/token", body, %{
                   "content-type" => "application/x-www-form-urlencoded"
                 }) do
              {:ok, 200, _, body} ->
                case Jason.decode(body) do
                  {:ok, %{"access_token" => tok}} when is_binary(tok) -> tok
                  _ -> exit({:shutdown, 1})
                end

              {:ok, s, _, _} ->
                IO.puts("[native] verify: STS mint HTTP " <> Integer.to_string(s))
                exit({:shutdown, 1})
            end
          end

          defp fail(surface, why) do
            IO.puts("[native] verify #{surface}: FAIL #{why}")
            :fail
          end

          defp clip(b) when is_binary(b), do: String.slice(b, 0, 160)
          defp clip(b), do: String.slice(inspect(b), 0, 160)

          defp json(body) do
            case Jason.decode(body) do
              {:ok, m} -> m
              {:error, _} -> %{}
            end
          end

          defp http(method, port, path, body \\ "", headers \\ %{}) do
            url = ~c"http://127.0.0.1:#{port}#{path}"

            base =
              Map.merge(
                %{"content-type" => "application/json"},
                if(is_map_key(headers, "content-type"),
                  do: %{},
                  else: %{"authorization" => "Bearer " <> :persistent_term.get({:nv, :token})}
                )
              )

            hdrs =
              Enum.map(Map.merge(base, headers), fn {k, v} ->
                {String.to_charlist(k), String.to_charlist(v)}
              end)

            ctype =
              case Map.get(headers, "content-type") do
                nil -> ~c"application/json"
                ct -> String.to_charlist(ct)
              end

            # Empty-body requests (GET/HEAD/DELETE) use httpc's 2-tuple form:
            # the 4-tuple form with an empty body makes httpc refuse the
            # request itself with {:error, :invalid_request} (witnessed on the
            # secrets GET leg).
            request =
              if body == "" do
                {url, hdrs}
              else
                {url, hdrs, ctype, String.to_charlist(body)}
              end

            case :httpc.request(method, request, [timeout: 15_000, connect_timeout: 10_000], []) do
              # NOTE: written via elem/2, not a two-element tuple pattern —
              # just treats a literal double-brace in a recipe line as
              # interpolation and fails to parse.
              {:ok, response} ->
                status = response |> elem(0) |> elem(1)
                # httpc returns text/* bodies as CHARLISTS — normalize to
                # binary so byte_size/== comparisons in the families are sane.
                resp_body =
                  case elem(response, 2) do
                    chars when is_list(chars) -> :erlang.list_to_binary(chars)
                    bin when is_binary(bin) -> bin
                  end

                {:ok, status, nil, resp_body}

              {:error, reason} ->
                {:error, inspect(reason)}
            end
          end
        end

        Native.Verify.run()

        # Console phase: the real Next.js enclave-loop console harness against
        # the SAME live native beam (mints its own STS bearer per :enforce).
        console_env = %{
          "SMALT_TEST_ARM_PORT" => "29447",
          "SMALT_TEST_EGRESS_PORT" => "29448",
          "PATH" => System.get_env("PATH") || ""
        }

        case System.cmd("node", ["scripts/enclave-loop.mjs"],
               cd: "workspace",
               env: console_env,
               into: IO.stream(:stdio, :line)
             ) do
          {_, 0} -> IO.puts("[native] verify console: enclave-loop.mjs PASS")
          {_, code} -> IO.puts("[native] verify console: enclave-loop.mjs exit #{code}"); exit({:shutdown, 1})
        end
    end

    System.stop(0)
    ELIXIR
    MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build-native}" NATIVE_PRIVATE_PORTS=1 \
      mix run --no-start "$EXS"

# Native lifecycle test: Hcl parse -> Engine apply -> State.plan (zero drift)
# -> State.destroy (verified cascade) -> residue must be EMPTY (fail-closed).
# This is the non-vacuity surface for the native engine: a broken Engine,
# Hcl, State, or ARM router shows up as DRIFT / failed cascade / residue.
test-native fixture="test/terraform_fixture":
    @just _native-lifecycle test

# Provision the fixture through the in-process engine, write the state JSON.
# Tier routing (operator spec): tier="native" (default) uses the in-process
# engine; tier="wire" is EXPLICIT OPT-IN to the external terraform path
# (scripts/tf_cleanroom.sh) and prints the wire-parity warning first.
# Invocation note: just 1.56 passes recipe arguments POSITIONALLY —
# `just apply fixture=test/terraform_fixture tier=wire` arrives with the
# literal 'name=' prefixes. The recipes below strip an optional 'name='
# prefix so both positional (`just apply . wire`) and assignment-style
# (`just apply fixture=... tier=wire`) invocations work.
apply fixture="test/terraform_fixture" tier="native":
    #!/usr/bin/env bash
    set -euo pipefail
    FIXTURE="{{fixture}}"; FIXTURE="${FIXTURE#fixture=}"
    TIER="{{tier}}"; TIER="${TIER#tier=}"
    if [[ "$TIER" == "wire" ]]; then
      echo "[WIRE-TIER] WARNING: routing apply through the EXTERNAL terraform path (tf_cleanroom.sh) — this validates wire parity with real terraform, NOT the native engine. Explicit opt-in acknowledged."
      TRUST="$(bash scripts/tf_trust_setup.sh status --json 2>/dev/null || true)"
      echo "[WIRE-TIER] trust gate: $TRUST"
      echo "$TRUST" | grep -q '"status":"PASS"' || {
        echo "[WIRE-TIER] REFUSED[TIER-WIRE-UNAVAILABLE]: wire tier requires a trusted-machine gate (status PASS); got: ${TRUST:-<no answer>}"
        exit 3
      }
      exec bash scripts/tf_cleanroom.sh
    elif [[ "$TIER" != "native" ]]; then
      echo "[native] REFUSED: unknown tier '$TIER' (want native|wire)"; exit 2
    fi
    exec env NATIVE_FIXTURE="$FIXTURE" just _native-lifecycle apply

# Destroy from a prior `just apply` state file; fails on any residue.
# tier="wire" delegates to the terraform cleanroom ladder (opt-in; warning).
destroy tier="native":
    #!/usr/bin/env bash
    set -euo pipefail
    TIER="{{tier}}"; TIER="${TIER#tier=}"
    if [[ "$TIER" == "wire" ]]; then
      echo "[WIRE-TIER] WARNING: routing destroy through the EXTERNAL terraform path (tf_cleanroom.sh) — the cleanroom ladder applies THEN destroys (real tf transition). Explicit opt-in acknowledged."
      TRUST="$(bash scripts/tf_trust_setup.sh status --json 0>/dev/null 2>&1 || true)"
      echo "[WIRE-TIER] trust gate: $TRUST"
      echo "$TRUST" | grep -q '"status":"PASS"' || {
        echo "[WIRE-TIER] REFUSED[TIER-WIRE-UNAVAILABLE]: wire tier requires a trusted-machine gate (status PASS); got: ${TRUST:-<no answer>}"
        exit 3
      }
      exec bash scripts/tf_cleanroom.sh
    elif [[ "$TIER" != "native" ]]; then
      echo "[native] REFUSED: unknown tier '$TIER' (want native|wire)"; exit 2
    fi
    exec just _native-lifecycle destroy

# Data-plane read-your-write parity audit WITHOUT terraform provisioning.
# Requires already-applied fixture state (tmp/native-enclave-state.json from
# `just apply`); if the state file is missing/empty the run is a loud
# SKIP-LOUD exit 3 with reason, never a fake pass. Phases: state-file parity
# -> zero-drift -> blob/secrets/cosmos read-your-write over real loopback
# HTTP on the private native beam -> the enclave-loop console harness
# (workspace/scripts/enclave-loop.mjs) against the same live beam.
verify fixture="test/terraform_fixture":
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cd "$ROOT"
    FIXTURE="{{fixture}}"; FIXTURE="${FIXTURE#fixture=}"
    STATE="${NATIVE_STATE:-{{NATIVE_STATE}}}"
    if [[ ! -s "$STATE" ]]; then
      echo "[SKIP-LOUD] verify: no applied fixture state at $STATE — run 'just apply' first"
      exit 3
    fi
    if [[ ! -f "$FIXTURE/main.tf" ]]; then
      echo "[native] verify: fixture dir missing: $FIXTURE"; exit 3
    fi
    exec env NATIVE_FIXTURE="$FIXTURE" just _native-lifecycle verify

# Apply + destroy + per-table residue audit (fail-closed on non-empty).
audit-residue:
    @just _native-lifecycle audit

# T5 clean-room ladder (scripts/tf_cleanroom.sh): fresh substrate, trust gate,
# terraform init/apply/plan -detailed-exitcode=0, data-plane audit, destroy.
# Name disclosure: root `test-wire` is the T2 mix tier; see module header.
cleanroom:
    @bash scripts/tf_cleanroom.sh

# Trust gate, machine-readable: {"status":"PASS|FAIL|UNREACHABLE","reason":...}
trust-status:
    @bash scripts/tf_trust_setup.sh status --json

# doctor.py --json receipt. Name disclosure: root `doctor` is the human mode;
# just aborts on duplicate recipe names, so this is the receipt variant.
doctor-json:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p docs/jira/v26.10.16
    set -o pipefail
    python3 scripts/doctor.py --json | tee docs/jira/v26.10.16/doctor-receipt.json

# SPC rolling control bands (config/bands.yaml) over the Chatman-invariant
# metrics: nfr3_delta_rss_kb, nfr4_residue_tables, native_stage_ms per stage.
# Tiers: PASS (silent) / EVENT 1-sigma / DISPATCH 2-sigma / FAIL-CLOSED 3-sigma
# (exit 1 + orphaned-key dump). Missing history = SEED mode, never a faked
# z-score. Receipt: docs/jira/v26.10.16/sdk-results/spc-bands.md
# Lane 431: the 1σ loop closes here — the gate's JSON verdict is piped to
# Smalt.Spc.Drift, which appends a CloudEvents "spc.drift" row to
# :smalt_event_messages (registry-gated; emission is only reachable when the
# gate exits 0, so a 3σ FAIL never reaches the event plane).
spc-check:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(python3 scripts/spc_gate.py)"
    printf '%s' "$out" | MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-_build-lane431} mix run --no-start -e '
      if :ets.info(:smalt_event_messages) == :undefined do
        :ets.new(:smalt_event_messages, [:ordered_set, :public, :named_table,
          read_concurrency: true, write_concurrency: true])
      end

      input = IO.read(:stdio, :eof)

      case Smalt.Spc.Drift.emit(input) do
        {:ok, :skipped} -> IO.puts("[spc-drift] no emission (skip)")
        {:ok, ids} -> IO.puts("[spc-drift] emitted: " <> Enum.join(ids, ","))
        {:error, {:malformed, reason}} ->
          IO.puts(:stderr, "[spc-drift] malformed gate verdict: " <> inspect(reason))
          exit({:shutdown, 1})
      end
    '

# ============================================================================
# Fix mode — protected-test freeze (Anthropic deterministic-freeze adaptation)
# ============================================================================
# Ritual: the failing test is the witness. `just fix-start test/foo_test.exs:NN`
# enters fix mode (marker .smalt/fix-mode, 0444), freezes the named test file
# (chmod 0444), records it in .smalt/fix-mode-tests. While fix mode is active,
# scripts/test_freeze_gate.sh refuses any working diff that touches test/.
# `just fix-end` lifts the freeze and restores 0644. Name disclosure: the task
# brief said `just preflight` already exists — it did not, so this module lands
# it here (doctor + freeze gate); the root Justfile is untouched.

# Enter fix mode. Usage: just fix-start test/path_test.exs[:line]
@fix-start TEST:
    #!/usr/bin/env bash
    set -euo pipefail
    file="{{TEST}}"; file="${file%%:*}"
    [ -f "$file" ] || { echo "TEST_FREEZE: test file not found: $file" >&2; exit 1; }
    case "$file" in test/*.exs) ;; *) echo "TEST_FREEZE: $file is not under test/" >&2; exit 1;; esac
    mkdir -p .smalt
    printf '1\n' > .smalt/fix-mode.tmp && mv .smalt/fix-mode.tmp .smalt/fix-mode
    chmod 0444 .smalt/fix-mode
    grep -Fxq "$file" .smalt/fix-mode-tests 2>/dev/null || printf '%s\n' "$file" >> .smalt/fix-mode-tests
    chmod 0444 "$file"
    echo "[FIX-MODE] on; frozen witness: $file (0444); recorded in .smalt/fix-mode-tests"

# Leave fix mode: remove marker, restore 0644 on all frozen witnesses.
@fix-end:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f .smalt/fix-mode-tests ]; then
      while IFS= read -r f; do
        [ -f "$f" ] && chmod 0644 "$f" && echo "[FIX-MODE] restored 0644: $f" || true
      done < .smalt/fix-mode-tests
    fi
    rm -f .smalt/fix-mode .smalt/fix-mode-tests
    echo "[FIX-MODE] off"

# Preflight: doctor + protected-test freeze gate. Name disclosure: no prior
# `preflight` recipe existed anywhere in the tree (grep receipt in module note
# above); landed here rather than editing the root Justfile.
preflight:
    python3 scripts/doctor.py
    bash scripts/test_freeze_gate.sh
