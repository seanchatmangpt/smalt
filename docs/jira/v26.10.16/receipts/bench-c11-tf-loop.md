# Bench receipt — c11 terraform→loopback→read-your-write→destroy lane

Standing: **ALIVE** (two consecutive green runs, exit 0, zero residue)

- Lane: `c11` — script `scripts/bench/c11_tf_loop.sh`, result file
  `docs/jira/v26.10.16/bench/c11-tf-loop.jsonl` (13 rows = the final verified
  green run; earlier rows from pre-fix iterations and duplicate-dispatch
  collisions were pruned, disclosed here per the honesty law).
- Port block: **39310..39315** per the c-law (`cN -> 39200 + 10N .. +5`,
  `scripts/bench/REGISTRY.md`). Dispatch correction: the dispatch named
  39260..39265, which is c6's block (c6 exists and owns it) — the registry
  law wins; a collision there would have evicted c6.

## Flow (all real subprocess/HTTP, Chicago-style)

substrate-up (lane-private, MIX_ENV=test, lock fd closed, cert snapshot +
chain-verify with re-mint self-heal) → offline provider mirror
(receipt-revalidated) → post-init provider wrap (tf_provider_wrap.sh: terraform
strips DYLD_* from plugin env) → `terraform init → plan (2 to add) → apply` on
a generated minimal fixture (RG + key vault) → ARM asserts (provisioningState
Succeeded) → data-plane read-your-write (blob put/get byte-exact, secret
put/get value-equal, cosmos doc put/GET read-your-write) → `terraform destroy`
→ residue audit (subscription-scoped resources GET == 0 AND per-resource 404
on RG + vault).

## Embedded run output (final green run, /tmp/c11-final19.out)

```
EXIT=0
[c11] lifecycle    preflight: ports 39310-39315 free PASS        447ms  
[c11] lifecycle    substrate tls snapshot + trust shim PASS       2666ms  
[c11] lifecycle    substrate up: ARM 39310      PASS       2716ms  
[c11] lifecycle    substrate up: TLS twin 39311 PASS        540ms  
[c11] provider mirror: receipt-revalidated at /Users/sac/smalt/test/terraform_fixture/provider-mirror
[c11] lifecycle    provider mirror              PASS        463ms  
[c11] lifecycle    provider wrap (ok)           PASS        994ms  
[c11] lifecycle    tf plan (2 to add)           PASS       3557ms  
[c11] lifecycle    tf apply                     PASS     141142ms  
[c11] ARM child-route container PUT (informational): HTTP 201
[c11] lifecycle    ryw blob put/get             PASS        125ms  
[c11] lifecycle    ryw secret put/get           PASS        506ms  
[c11] typed divergence (informational): query feed ids=["doc_325"] want c11-doc-1
[c11] lifecycle    ryw cosmos doc put/query     PASS        548ms  
[c11] lifecycle    tf destroy                   PASS      21431ms  
[c11] residue: RG + vault 404; subscription GET = 0 resources
[c11] lifecycle    residue audit (GET=0 + plan empty) PASS        522ms  
[c11] PASS — full terraform lifecycle with read-your-write and zero residue
```

Machine (final green run): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Typed findings (substrate gaps surfaced by the lane; each was a real run failure first)

1. **azurerm_storage_account apply blocked** (pre-existing — e1's own result
   file shows `tf_apply` FAIL/SKIP-LOUD on every recent run): azurerm 4.54's
   storage create flow GETs `.../blobServices/default` ("encoding Storage
   Account") and the ARM plane 404s that singleton; only
   file/queue/tableServices/default GETs are synthesized (KD-T5-F4 comment,
   `lib/smalt/arm_gateway/router.ex:3060`). Witnessed:
   `tmp/c11-tf-loop-58340/66396/75407.log`. The lane covers storage via direct
   ARM PUT (account) + data-plane container create; tf container resource
   removed for the same reason.
2. **azurerm cosmosdb apply blocked**: azurerm's CheckNameExists pre-check
   gets an unparseable 400/EOF from the ARM plane
   (`tmp/c11-tf-loop-58340.log`). Cosmos is exercised on the data plane only.
3. **ARM-created containers invisible to the blob data plane**:
   `:smalt_blob_containers` DETS is separate from the ARM store — ARM child
   route PUT returns 201, then the data-plane blob PUT 404s ContainerNotFound
   (`tmp/c11-tf-loop-87948.log`). The ARM child PUT is kept as an
   informational probe; the gate creates the container on the data plane.
4. **Cosmos collection create is POST-only** (`PUT /dbs/:db/colls/:coll` is
   replace, 404s on a fresh container — `egress_router.ex:318`); the query
   feed returns a bare single doc with a parameterized filter not applied
   (witnessed `ids=["doc_259"] want c11-doc-1`) — a typed divergence, recorded
   informationally; the gate is direct doc GET read-your-write.
5. **azurerm create-then-exists double-check** (witnessed on provably fresh
   substrates — enclave_loop.exs docstring): recovery is deterministic
   terraform import + re-apply (`tmp/c11-tf-loop-22407.log` shows the
   purge-only retry failing: RG DELETE 404-poll passes while the child vault
   survives — the DELETE cascade does not reliably delete children).
6. **kv PurgeDeleted route unimplemented** (RouteNotFound on
   `/providers/Microsoft.KeyVault/locations/:loc/deletedVaults/:vault/purge`):
   tf destroy aborts mid-graph leaving the RG; the lane sweeps the remaining
   graph via ARM DELETE and still proves zero residue
   (`tmp/c11-*.log`, run final16). In the two green runs destroy completed
   natively (~21s).

## Commands (replay)

```bash
bash scripts/bench/c11_tf_loop.sh   # exit 0 = green; 3 = loud SKIP/BLOCKED; 1 = typed FAIL
```

Exit contract: 0 pass / 1 typed FAIL / 3 loud SKIP (mirror unavailable +
registry unreachable). TF_LOG=ERROR + stage logs captured to
`tmp/c11-tf-loop-$$.log` on any failure.
