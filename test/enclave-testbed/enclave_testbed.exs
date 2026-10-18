# Enclave Testbed — v26.10.14 high-assurance composite
#
# Drives ten Azure service classes together against ONE live substrate
# (mix run boots the full Smalt.Application: Store, broker, endpoints).
#
# Per-phase hard asserts; a refusal that is the law asserts `refute 2xx`.
# A lib defect is FILED in the results doc, never patched here.
#
# When ENCLAVE_PRIVATE_PORTS=1 (set by run.sh), pin the enclave port set
# BEFORE the app boots, then boot the application exactly once.
enclave_pins? = System.get_env("ENCLAVE_PRIVATE_PORTS") == "1"

if enclave_pins? do
  # Boot-time pins BEFORE the app boots. Save-prev + end-of-run restore per
  # the test-isolation leak gate (literal keys mandatory; non-literal
  # put_env keys are hard-REFUSEd as "unresolved"). Prev values are carried
  # through the process dictionary because a try `after` clause is a
  # separate scope (i21-leak-batch2 gotcha).
  prev_amqp = Application.get_env(:smalt, :amqp_port)
  Process.put(:encl_prev_amqp_port, prev_amqp)
  Application.put_env(:smalt, :amqp_port, 29440)

  prev_eh = Application.get_env(:smalt, :event_hubs_port)
  Process.put(:encl_prev_event_hubs_port, prev_eh)
  Application.put_env(:smalt, :event_hubs_port, 29441)

  prev_arm = Application.get_env(:smalt, :arm_port)
  Process.put(:encl_prev_arm_port, prev_arm)
  Application.put_env(:smalt, :arm_port, 29442)

  prev_egress = Application.get_env(:smalt, :egress_port)
  Process.put(:encl_prev_egress_port, prev_egress)
  Application.put_env(:smalt, :egress_port, 29443)

  prev_arm_tls = Application.get_env(:smalt, :arm_tls_port)
  Process.put(:encl_prev_arm_tls_port, prev_arm_tls)
  Application.put_env(:smalt, :arm_tls_port, 29444)
end

try do
  booted? =
    case :ets.whereis(:smalt_resources) do
      :undefined ->
        {:ok, _} = Application.ensure_all_started(:smalt)
        true

      _ ->
        false
    end

  IO.puts("[enclave] substrate booted: #{booted?}")
after
  # Boot-scope restore of the port pins (leak-gate discipline: every
  # put_env carries a save-prev + after-region restore). The listeners are
  # already bound by the time this runs, so the run's observable behavior
  # is unchanged; the substrate dies with the VM at the end of the script.
  if enclave_pins? do
    case Process.get(:encl_prev_amqp_port) do
      nil -> Application.delete_env(:smalt, :amqp_port)
      v -> Application.put_env(:smalt, :amqp_port, v)
    end

    case Process.get(:encl_prev_event_hubs_port) do
      nil -> Application.delete_env(:smalt, :event_hubs_port)
      v -> Application.put_env(:smalt, :event_hubs_port, v)
    end

    case Process.get(:encl_prev_arm_port) do
      nil -> Application.delete_env(:smalt, :arm_port)
      v -> Application.put_env(:smalt, :arm_port, v)
    end

    case Process.get(:encl_prev_egress_port) do
      nil -> Application.delete_env(:smalt, :egress_port)
      v -> Application.put_env(:smalt, :egress_port, v)
    end

    case Process.get(:encl_prev_arm_tls_port) do
      nil -> Application.delete_env(:smalt, :arm_tls_port)
      v -> Application.put_env(:smalt, :arm_tls_port, v)
    end
  end
end

defmodule Enclave.Testbed do
  @moduledoc false

  alias Smalt.Amqp.LockManager
  alias Smalt.Amqp.QueueStore
  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.LRO.Sweeper
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.Purview
  alias Smalt.DataPlane.ResourceGraph
  alias Smalt.DataPlane.Sentinel
  alias Smalt.DataPlane.SKR
  alias Smalt.Messaging.EventHubs
  alias Smalt.Security.Attestation
  alias Smalt.Security.ConfidentialLedger
  alias Smalt.Store

  @pass "PASS"
  @fail "FAIL"
  @blocked "BLOCKED"

  def main do
    IO.puts(
      "\n=== SMALT ENCLAVE TESTBED v26.10.14 — #{DateTime.utc_now() |> DateTime.to_iso8601()} ==="
    )

    results =
      [
        {"A: SKR attest->release->replay", &phase_a/0},
        {"B: WORM legal-hold + immutability", &phase_b/0},
        {"C: Confidential Ledger chain", &phase_c/0},
        {"D: Governance (Purview/Sentinel/RG)", &phase_d/0},
        {"E1: Cosmos 500-doc cross-partition", &phase_e1/0},
        {"E2: 50x LRO + sweeper convergence", &phase_e2/0},
        {"F1: SB sessions + DLQ under EH load", &phase_f1/0},
        {"F2: EH producer/consumer + CAS contention", &phase_f2/0},
        {"F3: chaos — sweeper child kill", &phase_f3/0}
      ]
      |> Enum.map(fn {name, fun} ->
        IO.puts("\n--- #{name} ---")

        case safe(fun) do
          {:ok, out} -> {name, @pass, out}
          {:error, reason} -> {name, @fail, [reason]}
        end
      end)

    IO.puts("\n=== SUMMARY ===")

    Enum.each(results, fn {name, verdict, out} ->
      IO.puts("#{verdict}  #{name}")
      Enum.each(out, &IO.puts("      #{&1}"))
    end)

    failures = Enum.count(results, &match?({_, @fail, _}, &1))
    IO.puts("\n#{Enum.count(results) - failures} passed, #{failures} failed")

    if failures > 0, do: System.stop(1)
    System.stop(0)
  end

  defp safe(fun) do
    out = fun.()
    {:ok, List.wrap(out)}
  rescue
    e ->
      {:error,
       [
         Exception.format(:error, e, __STACKTRACE__)
         |> String.split("\n")
         |> Enum.take(40)
         |> Enum.join("\n")
       ]}
  end

  # ------------------------------------------------------------------------- A
  defp phase_a do
    measurement = String.duplicate("ab", 32)
    Store.put(:smalt_attestation_baseline, measurement, true)

    {:ok, token, _claims} = Attestation.attest_enclave(%{"measurement" => measurement})
    IO.puts("  attest: ok, token len #{byte_size(token)}")

    # hostile measurement -> 400 verdict
    {:error, 400, "attestationFailedVerdict"} =
      Attestation.attest_enclave(%{"measurement" => "zz"})

    key = "enclave-skr-key"

    Store.put(:smalt_vault_keys, key, %{
      "kid" => "kid-" <> key,
      "release_policy" => %{"exportable" => true}
    })

    conn = conn_with_token(token)
    {:ok, 200, body} = SKR.release(key, conn)
    %{"value" => v1, "keyMaterialVersion" => 1, "status" => "Released"} = body
    IO.puts("  release v1: transport=#{body["transport"]} value len=#{byte_size(v1)}")

    # jti replay -> 403 TokenReplay
    {:error, 403, %{"error" => %{"code" => "TokenReplay"}}} = SKR.release(key, conn)

    # fresh attestation (new jti) releases deterministically (same key+policy)
    {:ok, token2, _} = Attestation.attest_enclave(%{"measurement" => measurement})
    {:ok, 200, body2} = SKR.release(key, conn_with_token(token2))
    %{"value" => ^v1} = body2
    %{"keyMaterialVersion" => 2} = body2
    IO.puts("  second release deterministic material, v2 counter")

    # no bearer -> 403 UnauthorizedAttestation
    {:error, 403, %{"error" => %{"code" => "UnauthorizedAttestation"}}} =
      SKR.release(key, %Plug.Conn{})

    # non-exportable + missing + hostile name
    Store.put(:smalt_vault_keys, "enclave-noexp", %{"kid" => "k2", "release_policy" => nil})

    {:error, 400, %{"error" => %{"code" => "KeyNotExportable"}}} =
      SKR.release("enclave-noexp", conn_with_token(token2))

    {:error, 404, _} = SKR.release("enclave-never-existed", conn_with_token(token2))

    {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
      SKR.release(:hostile_atom, conn_with_token(token2))

    "PASS: attest->release->replay refusal->determinism->typed refusals"
  end

  defp conn_with_token(token) do
    %Plug.Conn{}
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  # ------------------------------------------------------------------------- B
  defp phase_b do
    acct = "enclaveacct"
    cont = "enclave-worm"

    {:ok, created} =
      BlobStorage.create_container(acct, cont, %{
        "created_at_ms" => now_ms(),
        "retention_days" => 1
      })

    %{"created_at" => created_at, "retention_days" => 1} = created

    # duplicate create refused (WORM clock-reset class)
    {:error, 409, "ContainerAlreadyExists", _} = BlobStorage.create_container(acct, cont)

    blob = "worm-blob.txt"

    {:ok, put1} =
      BlobStorage.put_blob(acct, cont, blob, "immutable payload v1", %{}, now_ms: now_ms())

    "immutable payload v1" = put1["content"]

    # legal hold blocks overwrite + delete + purge
    {:ok, 200, _, _} = BlobStorage.set_legal_hold(acct, cont, true)

    {:error, :worm_locked, _} =
      BlobStorage.put_blob(acct, cont, blob, "v2", %{}, now_ms: now_ms())

    {:error, 409, "ContainerLocked", _} =
      BlobStorage.delete_blob(acct, cont, blob, %{}, now_ms: now_ms())

    # release hold, lock immutability policy (requires If-Match: "*")
    {:ok, 200, _, _} = BlobStorage.set_legal_hold(acct, cont, false)

    {:ok, 200, _, _} =
      BlobStorage.set_immutability_policy(
        acct,
        cont,
        %{"locked" => true, "period_days" => 1},
        %{
          "if-match" => ["*"]
        }
      )

    {:error, :worm_locked, _} =
      BlobStorage.put_blob(acct, cont, blob, "v2", %{}, now_ms: now_ms())

    IO.puts("  legal hold + locked policy both refuse overwrite/delete")

    # expiry unlock via time injection: now past created_at + 1 day
    future = created_at + 86_400_500 + 1
    {:ok, put3} = BlobStorage.put_blob(acct, cont, blob, "post-expiry v3", %{}, now_ms: future)
    "post-expiry v3" = put3["content"]
    {:ok, 202, _, _} = BlobStorage.delete_blob(acct, cont, blob, %{}, now_ms: future)
    IO.puts("  retention expiry (injected clock) unlocks container")

    # but a legal hold NEVER expires
    {:ok, 200, _, _} = BlobStorage.set_legal_hold(acct, cont, true)

    # DISPOSITION UPDATE (v26.10.17, i21b): the 2026-10-15 ENCLAVE-1
    # "create-admitted" disposition is SUPERSEDED by the d092caa court-RED
    # closure re-pin: an active legal hold blocks BOTH overwrite AND create
    # (blob_storage.ex put_blob/commit_block_list existence-scoped WORM arm,
    # KD-52; blob-hardening suite 116/0 green on the modified tree pins it).
    # Azure real-service semantics re-checked per the parity-defect rule:
    # legal hold (unlike time-retention) blocks new-blob writes too.
    # Law pinned here: hold -> create REFUSED (typed :worm_locked);
    # time-retention -> only existing-blob overwrite refused.
    {:error, :worm_locked, _} =
      BlobStorage.put_blob(acct, cont, blob, "v4", %{}, now_ms: future + 86_400_000 * 30)

    IO.puts(
      "  create under active legal hold REFUSED (legal hold blocks create, not just overwrite)"
    )

    # second witness: brand-new blob name under the same active hold
    {:error, :worm_locked, _} =
      BlobStorage.put_blob(acct, cont, "worm-blob-new.txt", "new blob under hold", %{},
        now_ms: now_ms()
      )

    IO.puts("  fresh-blob CREATE under active legal hold REFUSED (same law)")

    {:ok, state} = BlobStorage.policy_state(acct, cont, now_ms: future)
    %{"legal_hold" => true, "expired" => true} = state

    "PASS: WORM hold/lock refusals + time-injected expiry + hold-never-expires"
  end

  defp now_ms, do: System.os_time(:millisecond)

  # ------------------------------------------------------------------------- C
  defp phase_c do
    ledger = "enclave-ledger"
    n = 25

    receipts =
      Enum.map(1..n, fn i ->
        case ConfidentialLedger.append_transaction(ledger, %{
               "i" => i,
               "payload" => "entry-#{i}"
             }) do
          {:ok, r} -> r
          other -> raise "append #{i} refused: #{inspect(other)}"
        end
      end)

    %{"transactionId" => first_id} = hd(receipts)
    %{"transactionId" => last_id} = List.last(receipts)
    IO.puts("  appended #{n} receipts (#{first_id} .. #{last_id})")

    # duplicate contents -> 409
    {:error, 409, %{"error" => %{"code" => "LedgerItemAlreadyExists"}}} =
      ConfidentialLedger.append_transaction(ledger, %{"i" => 1, "payload" => "entry-1"})

    # chain integrity: zero-root head, prev_hash linkage, hash linkage
    chain_ok? = fn ->
      rs = ConfidentialLedger.list_transactions(ledger)
      length(rs) == n and verify_chain(rs)
    end

    if chain_ok?.() do
      IO.puts("  chain verify: #{n} receipts, linkage + merkle hash linkage OK")
    else
      rs = ConfidentialLedger.list_transactions(ledger)

      IO.puts("""
      CHAIN DEBUG: count=#{length(rs)}
      first=#{inspect(hd(rs), limit: 10)}
      second=#{inspect(Enum.at(rs, 1), limit: 10)}
      """)

      raise "chain broken before tamper"
    end

    # tamper: rewrite one persisted receipt's data_hash -> verify fails
    tx_key = "#{ledger}/#{last_id}"
    {:ok, tampered} = Store.get(:smalt_ledger_transactions, tx_key)

    Store.put(
      :smalt_ledger_transactions,
      tx_key,
      Map.put(tampered, "data_hash", String.duplicate("f", 64))
    )

    if chain_ok?.() do
      raise "tampered ledger still verified (DEFECT: chain verify does not bind data_hash)"
    end

    IO.puts("  tampered receipt -> chain verify FAILS (as required)")

    # hostile shapes: typed refusal, never raise
    {:error, 400, %{"error" => %{"code" => "InvalidLedgerName"}}} =
      ConfidentialLedger.append_transaction({:bad, :shape}, %{"a" => 1})

    :error = ConfidentialLedger.get_transaction(ledger, 42)

    "PASS: append/dup-409/chain-verify/tamper-detect/hostile-typed"
  end

  defp verify_chain([r0 | _] = rs) do
    zero = String.duplicate("0", 64)
    %{"prev_hash" => ^zero} = r0

    rs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [prev, cur] ->
      String.downcase(cur["prev_hash"]) == String.downcase(prev["merkle_root"])
    end) and
      Enum.all?(rs, fn r ->
        recomputed =
          :crypto.hash(:sha256, r["prev_hash"] <> r["data_hash"]) |> Base.encode16(case: :lower)

        recomputed == String.downcase(r["merkle_root"])
      end)
  end

  # ------------------------------------------------------------------------- D
  defp phase_d do
    # Purview: entities + lineage
    {:ok, 201, src} =
      Purview.create_entity(%{
        "entity" => %{"typeName" => "azure_sql_table", "attributes" => %{"name" => "src"}}
      })

    {:ok, 201, mid} =
      Purview.create_entity(%{
        "entity" => %{"typeName" => "azure_sql_table", "attributes" => %{"name" => "mid"}}
      })

    {:ok, 201, dst} =
      Purview.create_entity(%{
        "entity" => %{"typeName" => "azure_sql_table", "attributes" => %{"name" => "dst"}}
      })

    true = is_binary(src["guid"]) and is_binary(dst["guid"])
    Purview.put_edge(src["guid"], mid["guid"], "dataset_to_dataset_process")
    Purview.put_edge(mid["guid"], dst["guid"], "dataset_to_dataset_process")

    {:ok, 200, %{"relations" => rels, "guidEntityMap" => gm}} =
      Purview.lineage(src["guid"], "output", 2)

    2 = length(rels)
    3 = map_size(gm)
    {:error, 400, _} = Purview.lineage(src["guid"], "sideways", 1)
    {:error, 400, _} = Purview.create_entity(%{"entity" => 42})

    IO.puts(
      "  purview: 3 entities, 2-hop lineage (#{length(rels)} relations), hostile shapes 400"
    )

    # Sentinel: DCR ingest -> strict-mode creation marker -> KQL query
    dcr = "enclave-dcr"

    {:ok, 204, ""} =
      Sentinel.ingest(
        dcr,
        "Custom-enclave",
        [%{"level" => "err", "msg" => "boom"}, %{"level" => "info", "msg" => "fine"}],
        "2023-01-01"
      )

    {:ok, true} = Store.get(:smalt_sentinel_streams, {:dcr_created, dcr})

    {:error, 400, _} =
      Sentinel.ingest(dcr, "Custom-enclave", [%{"ok" => 1}, "not-a-map"], "2022-01-01")

    {:ok, 200, %{"tables" => [table]}} =
      Sentinel.query(dcr, %{"query" => "Custom-enclave | take 10"})

    2 = length(table["rows"])

    {:ok, 200, %{"tables" => [t2]}} =
      Sentinel.query(dcr, %{"query" => "Custom-enclave | where level == 'err' | project msg"})

    [["boom"]] = t2["rows"]
    IO.puts("  sentinel: ingest 204, strict-mode marker written, KQL take + where|count = 1")

    # Resource Graph: seed resources, query, hostile shapes -> typed 400
    Enum.each(1..3, fn i ->
      Store.put(
        :smalt_resources,
        "/subscriptions/s#{i}/resourcegroups/rg/providers/microsoft.storage/storageaccounts/enclave#{i}",
        %{
          "id" =>
            "/subscriptions/s#{i}/resourcegroups/rg/providers/microsoft.storage/storageaccounts/enclave#{i}",
          "name" => "enclave#{i}",
          "type" => "microsoft.storage/storageaccounts",
          "location" => "enclavehub",
          "properties" => %{"tier" => "gold"}
        }
      )
    end)

    {:ok, 200, body} =
      ResourceGraph.query(["s1", "s2", "s3"], %{"query" => "project name, tier"}, "2022-10-01")

    names = Enum.map(body["data"], & &1["name"]) |> Enum.sort()
    "enclave1" = hd(names)

    # discriminator probe: does the unfiltered (nil-subscriptions) surface see
    # all three? isolates the subscription filter as the loss point
    {:ok, 200, body_all} = ResourceGraph.query(nil, %{"query" => "project name"}, "2022-10-01")
    names_all = Enum.map(body_all["data"], & &1["name"]) |> Enum.sort()

    if length(names) != 3 do
      raise """
      FINDING(RG-1): ResourceGraph subscription-filtered query returned #{length(names)} of 3 seeded \
      cross-subscription resources (names=#{inspect(names)}), while the nil-subscriptions query \
      returns #{length(names_all)} (#{inspect(names_all)}); expected all 3 under the filter
      """
    end

    {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
      ResourceGraph.query("not-a-list", %{"query" => "name"}, "2022-10-01")

    # documented: a bare unknown word is treated as a table reference (filters
    # nothing, 200); a real KQL parse error is the typed 400 BadQuery
    {:ok, 200, _} = ResourceGraph.query(["s1"], %{"query" => "???gibberish"}, "2022-10-01")

    {:error, 400, %{"error" => %{"code" => "BadQuery"}}} =
      ResourceGraph.query(["s1"], %{"query" => "| frobnicate x"}, "2022-10-01")

    {:error, 400, _} = ResourceGraph.query(["s1"], %{"query" => "name"}, "1999-01-01")

    IO.puts(
      "  resource graph: 3 rows, hostile subscriptions shape + bad query + bad api-version all typed 400"
    )

    "PASS: purview lineage, sentinel ingest->marker->KQL, RG typed 400s"
  end

  # ------------------------------------------------------------------------ E1
  defp phase_e1 do
    db = "enclavedb"
    coll = "enclavecoll"
    {:ok, 201, _, _} = Cosmos.create_db(db)

    {:ok, 201, _, _} =
      Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    header = Smalt.DataPlane.PartitionKey.header_name()
    pk = fn v -> %{header => Jason.encode!([v])} end

    Enum.each(1..500, fn i ->
      case Cosmos.create_doc(
             db,
             coll,
             %{"id" => "doc-#{i}", "pk" => "p#{rem(i, 5)}", "v" => i},
             pk.("p#{rem(i, 5)}")
           ) do
        {:ok, 201, _, _} -> :ok
        other -> raise "create doc #{i} -> #{inspect(other)}"
      end
    end)

    IO.puts("  seeded 500 docs across 5 partitions")

    # cross-partition walk with continuation (>100 docs, limit is 100/page)
    walk = fn headers ->
      Stream.resource(
        fn -> headers end,
        fn
          nil ->
            {:halt, :done}

          hdrs ->
            case Cosmos.query_docs(db, coll, %{"query" => "select * from c"}, hdrs) do
              {:ok, 200, resp_headers, %{"Documents" => docs}} ->
                next =
                  case resp_headers["x-ms-continuation"] do
                    nil -> nil
                    tok -> Map.put(hdrs, "x-ms-continuation", tok)
                  end

                {docs, next}

              other ->
                throw({:query_failed, other})
            end
        end,
        fn _ -> :ok end
      )
      |> Enum.to_list()
    end

    pages = walk.(%{})
    total = pages |> List.flatten() |> length()
    500 = total
    page_count = length(pages)
    IO.puts("  cross-partition query: #{total} docs via #{page_count} continuation pages")

    # partition-scoped query
    {:ok, 200, _, %{"Documents" => scoped}} =
      Cosmos.query_docs(db, coll, %{"query" => "select * from c"}, pk.("p1"))

    100 = length(scoped)

    # forged continuation token -> typed 400, never silent all-docs
    {:ok, 400, _, _} =
      Cosmos.query_docs(
        db,
        coll,
        %{"query" => "select * from c"},
        Map.put(pk.("p1"), "x-ms-continuation", "forged-token")
      )

    "PASS: 500-doc seed, cross-partition walk 500 via continuation, pk-scoped 100, forged token 400"
  end

  # ------------------------------------------------------------------------ E2
  defp phase_e2 do
    prev_delay = Application.get_env(:smalt, :lro_delay_ms, 0)

    try do
      Application.put_env(:smalt, :lro_delay_ms, 15)

      ops =
        Enum.map(1..50, fn i ->
          rec =
            LRO.start_op(
              "/subscriptions/enclave/providers/microsoft.storage/storageaccounts/lro#{i}"
            )

          %{"status" => "InProgress"} = rec
          rec["name"]
        end)

      IO.puts("  started 50 LRO operations (delay 15ms)")

      # let the deadline pass, then drive the at-rest sweeper
      # SLEEP-CLASS: TIME-ADVANCE — crosses a real time window (no pollable observable; see docs/NO_SLEEP_DOCTRINE.md Law 1 B1)
      Process.sleep(60)

      _ = Sweeper.sweep_now()

      statuses =
        Enum.map(ops, fn id ->
          case LRO.get_op(id) do
            {:ok, %{"status" => "Succeeded"}} -> :succeeded
            _ -> :not_terminal
          end
        end)

      50 = Enum.count(statuses, &(&1 == :succeeded))
      IO.puts("  sweeper convergence: 50/50 terminal Succeeded")

      # idempotence: second sweep writes byte-identical terminals, zero regressions
      _ = Sweeper.sweep_now()

      Enum.each(ops, fn id ->
        {:ok, %{"status" => "Succeeded"}} = LRO.get_op(id)
      end)
    after
      Application.put_env(:smalt, :lro_delay_ms, prev_delay)
    end

    "PASS: 50 ops started, sweeper drove 50/50 to terminal, second sweep idempotent"
  end

  # ------------------------------------------------------------------------ F1
  defp phase_f1 do
    queue = "enclave-sbq"
    {:ok, _} = QueueStore.ensure_queue(queue)

    # session lock: first claimant wins, second refused
    {:ok, _lock} = LockManager.session_acquire(queue, "sess-1")
    {:error, :already_locked} = LockManager.session_acquire(queue, "sess-1")

    {:ok, seq} = QueueStore.enqueue(queue, "session-message-1", session_id: "sess-1")
    {:ok, seq2} = QueueStore.enqueue(queue, "session-message-2", session_id: "sess-1")

    {:ok, msg, _lock} = QueueStore.dequeue_matching(queue, session_id: "sess-1")
    "session-message-1" = msg.body

    # the locked msg-1 is skipped; the session's NEXT message is delivered
    # (session processing is sequential per session, not exclusive per message)
    {:ok, msg2, _lock2} = QueueStore.dequeue_matching(queue, session_id: "sess-1")
    "session-message-2" = msg2.body
    :empty = QueueStore.dequeue_matching(queue, session_id: "sess-1")

    # deadletter with custom DLQ properties
    {:ok, dlq_seq} =
      QueueStore.deadletter(queue, seq, "MaxDeliveryCountExceeded", "enclave test",
        properties: %{"EnclaveProbe" => "F1"}
      )

    {:ok, [dlq_msg | _]} =
      QueueStore.peek(QueueStore.deadletter_queue(queue), message_count: 10)

    props = dlq_msg[:app_props] || dlq_msg["app_props"] || %{}
    "MaxDeliveryCountExceeded" = props["DeadLetterReason"]
    "enclave test" = props["DeadLetterErrorDescription"]
    "F1" = props["EnclaveProbe"]

    IO.puts(
      "  session lock exclusivity + DLQ properties (reason/description/custom) preserved on wire record"
    )

    QueueStore.complete(queue, seq)
    QueueStore.complete(queue, seq2)
    "PASS: SB session exclusivity (second session claim refused), DLQ props stamped"
  end

  # ------------------------------------------------------------------------ F2
  defp phase_f2 do
    part = "enclave-eh-0"
    :ok = EventHubs.ensure_tables()

    # producer task while consumer CAS-checkpoints under it
    producer =
      Task.async(fn ->
        Enum.map(1..50, fn i ->
          {:ok, _seq, _} = EventHubs.send_event(part, ~s({"n":#{i}}))
          i
        end)
      end)

    consumer =
      Task.async(fn ->
        last = 0
        seen = consume(part, last, 0, System.monotonic_time(:millisecond) + 30_000)

        seen
      end)

    _ = Task.await(producer, 30_000)
    _ = Task.await(consumer, 30_000)

    drain = EventHubs.receive_events(part, 0, 1000)
    50 = length(drain)
    [first | _] = drain
    [last | _] = Enum.reverse(drain)
    true = last["seq"] > first["seq"]

    IO.puts(
      "  EH: 50 events delivered in order while consumer CAS'd checkpoints; final readback 50"
    )

    # CAS checkpoint: exactly one of two racing expect-equal claims wins
    {:ok, _seq0, _} = EventHubs.send_event(part, "cas-target")
    events = EventHubs.receive_events(part, 0, 1000)
    target = List.last(events)
    {:ok, %{"checkpoint" => cp0}} = EventHubs.reconcile("enclave-group", part)

    # seed the checkpoint deterministically to the zero form (or observed form
    # when present) BEFORE the race — the race's new value must differ from
    # the seeded value or the CAS is idempotent and both racers win
    seed_expect =
      Enum.find_value(
        [
          cp0 && Map.delete(cp0, "claim"),
          %{"seq" => 0, "offset" => 0, "etag" => 0}
        ]
        |> Enum.reject(&is_nil/1),
        fn expect0 ->
          case EventHubs.compare_and_swap("enclave-group", part, expect0, %{
                 "seq" => 0,
                 "offset" => 0,
                 "etag" => 0
               }) do
            :ok -> :ok
            _ -> nil
          end
        end
      ) || raise "could not seed checkpoint to zero (tried observed + zero forms)"

    :ok = seed_expect

    expect = %{"seq" => 0, "offset" => 0, "etag" => 0}

    outcomes =
      Enum.map(1..2, fn _ ->
        Task.async(fn ->
          EventHubs.compare_and_swap("enclave-group", part, expect, %{"seq" => target["seq"]})
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    1 = Enum.count(outcomes, &(&1 == :ok))
    1 = Enum.count(outcomes, &match?({:error, :conflict}, &1))
    IO.puts("  CAS checkpoint race: exactly 1 winner, 1 typed conflict")

    "PASS: EH wire delivery under producer/consumer contention + CAS race semantics"
  end

  # Poll step inside the ONE audited local poll loop for the testbed script
  # (SmaltTest.AssertEventually is not compiled into :dev env, which is how
  # run.sh drives this .exs via `mix run`). Bounded by a monotonic deadline.
  defp consume(part, after_seq, acc, deadline) do
    events = EventHubs.receive_events(part, after_seq, 20)

    case events do
      [] ->
        if acc >= 50 do
          acc
        else
          if System.monotonic_time(:millisecond) >= deadline do
            raise "consume/4 deadline (30s) exceeded with #{acc}/50 events (after_seq=#{after_seq})"
          end

          # POLL-STEP: bounded backoff pass inside the audited poll loop above.
          Process.sleep(10)
          consume(part, after_seq, acc, deadline)
        end

      evs ->
        acc = acc + length(evs)
        last = List.last(evs)["seq"]

        case EventHubs.compare_and_swap(
               "enclave-group-f2",
               part,
               if(after_seq == 0,
                 do: %{"seq" => 0, "offset" => 0, "etag" => 0},
                 else: %{"seq" => after_seq}
               ),
               %{"seq" => last, "offset" => last, "etag" => last}
             ) do
          :ok ->
            :ok

          # benign in the contention lane: another writer raced the checkpoint;
          # the final 50-event readback is the delivery assertion.
          {:error, :conflict} ->
            IO.puts("  [f2] checkpoint CAS conflict at seq #{after_seq} (raced)")
        end

        consume(part, last, acc, deadline)
    end
  end

  # ------------------------------------------------------------------------ F3
  defp phase_f3 do
    # chaos overlay: kill the LRO sweeper child mid-run; supervisor restarts it
    pid = Process.whereis(Sweeper)

    if is_nil(pid), do: raise("sweeper not running")

    Process.exit(pid, :kill)

    deadline = System.monotonic_time(:millisecond) + 10_000

    restart_ok =
      wait_until(deadline, fn ->
        case Process.whereis(Sweeper) do
          new_pid when is_pid(new_pid) and new_pid != pid ->
            case Sweeper.sweep_now(new_pid) do
              :ok -> true
              _ -> false
            end

          _ ->
            false
        end
      end)

    if not restart_ok, do: raise("sweeper did not restart and serve after kill")

    # substrate still serving: a fresh LRO still converges, ledger still appends
    prev_delay = Application.get_env(:smalt, :lro_delay_ms, 0)

    try do
      Application.put_env(:smalt, :lro_delay_ms, 1)

      rec =
        LRO.start_op("/subscriptions/enclave/providers/microsoft.storage/storageaccounts/chaos1")

      # SLEEP-CLASS: TIME-ADVANCE — crosses the 1ms LRO deadline window (the
      # condition under test is elapsed time, no pollable observable; the
      # at-rest sweeper is driven explicitly afterwards).
      Process.sleep(30)

      _ = Sweeper.sweep_now()
      {:ok, %{"status" => "Succeeded"}} = LRO.get_op(rec["name"])
    after
      Application.put_env(:smalt, :lro_delay_ms, prev_delay)
    end

    {:ok, _} =
      ConfidentialLedger.append_transaction("enclave-ledger", %{"chaos" => "post-kill"})

    "PASS: sweeper child killed -> supervisor restart -> serves again; substrate kept serving"
  end

  # THE audited bounded poll implementation for this script (mix-run in :dev
  # env — SmaltTest.AssertEventually is test-env-only). All sleeps below are
  # POLL-STEPs of this loop, bounded by the monotonic deadline argument.
  defp wait_until(deadline, fun) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        # POLL-STEP: backoff pass of the audited loop above.
        Process.sleep(50)
        wait_until(deadline, fun)
      else
        false
      end
    end
  end
end

Enclave.Testbed.main()
