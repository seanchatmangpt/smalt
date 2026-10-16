# CLI-4 receipt — SDK test lanes (Gate 1, part A)

Lane: CLI-4, 2026-10-15. Suite: `smalt-cli/tests/` (24 tests, 4 lanes + conftest).
Runner env: `/Users/sac/smalt/smalt-cli/.venv-cli` (py3.13, pytest 9.0.3, requests,
azure-storage-blob / azure-cosmos / azure-mgmt-resource / azure-mgmt-resourcegraph /
azure-identity).

## Files (owned)

- `/Users/sac/smalt/smalt-cli/tests/conftest.py` — session fixture reading
  `SMALT_ARM` / `SMALT_EGRESS`; health probe `GET /metadata/endpoints`; on
  miss: loud `#`-banner SKIP-PENDING with the boot command; never a fake pass.
  Verified: dead ports → `24 skipped in 0.15s`, exit 0.
- `tests/test_identity.py` (6 tests)
- `tests/test_blob.py` (6 tests)
- `tests/test_cosmos.py` (10 tests incl. 5 parametrized refusals + root-alias
  admission)
- `tests/test_resourcegraph.py` (3 tests)

## Execution

Substrate booted by `/tmp/cli4-boot.sh` under EXCLUSIVE
`flock /tmp/smalt-substrate.lock`, private ports arm=39643 egress=39644
(arm_tls 39645), MIX_ENV=test.

- **Phase A (anonymous substrate)** → blob / cosmos / resourcegraph lanes:
  `18 passed in 0.43s`
- **Phase B (enforce substrate, `auth_mode=:enforce` + explicit
  sts_signing_secret)** → identity lane: `6 passed in 0.10s`
- Full log: `/tmp/cli4-run3.log`; boot script `/tmp/cli4-boot.sh`.

## Why two phases

`config/test.exs` sets `auth_mode: :anonymous`; the repo's blob/cosmos/rg
probes (py_storage_blob, py_cosmos, py_resourcegraph_monitor) run against that
mode. The identity 401 probes (py_auth_keyvault raw auth probes) require the
enforce-mode substrate that boot_substrate.py builds. One substrate cannot
serve both honestly, so the runner boots each and runs its matching lanes.
The two-phase runner is the receipted procedure for re-running the lanes.

## Per-suite status

| suite | status | evidence |
|---|---|run||
| identity | 6/6 PASS (enforce substrate) | tampered sig → 401 `SignatureVerificationFailed`; self-minted wrong secret → same; expired → 401 `TokenExpired`; tokenless → 401 + `WWW-Authenticate: Bearer`; client_credentials mint → aud/exp/iat/iss claims verified |
| blob | 6/6 PASS | container create default-immutable (admission proven by upload; Get Container Properties NOT probed — ISO-8601 Last-Modified divergence, py probe p10), mutable opt-out via `x-ms-immutable-policy: false`, upload/download multibyte roundtrip, immutable overwrite → 409 `ContainerLocked`, stale If-Match → 412, `results_per_page=-7` → 400 |
| cosmos | 10/10 PASS | whitelist admits `SELECT * FROM c` AND `SELECT * FROM root` (see finding below); 400s: `SELECT c.id FROM c`, `WHERE`, `VALUE`, `" CosmosDB"`, `OFFSET 1 LIMIT 1`; stale-etag 412 replace+delete, fresh etag replace ok; 120 docs @ max_item_count=10 → multi-page + continuation-token resume = 120 |
| resourcegraph | 3/3 PASS | seeded 5 storage accounts; $top=2 skipToken walk → 5 unique names, terminates; default top: count=totalRecords=5, no skipToken; wire-level bare-string `subscriptions` → 400 `InvalidParameter` (SDK types refuse client-side, per py7 p04/p04b) |

## Findings (cross-lane, not owned)

1. **py_cosmos.py is stale vs. current gate**: `SELECT * FROM root` is
   ADMITTED by `lib/smalt/data_plane/cosmos.ex` `@sql_whitelist`
   (`^select\s+\*\s+from\s+[A-Za-z_][A-Za-z0-9_]*$`) — any `<alias>` matches.
   The repo probe expects 400 there; my lane pins current truth and names the
   drift.
2. First combined run (one anonymous substrate): 15 failed/9 passed, mostly
   the 401 class (substrate not in enforce mode). Diagnosed as mode mismatch,
   not a subject defect — fixed by the two-phase runner, not by loosening
   assertions.
3. `pkill -f smalt` in a boot script is a footgun on a shared checkout
   (would kill sibling lanes' substrates); removed from the runner.

## Honesty gates

- No substrate reachable → all 24 SKIP with the boot hint (verified: `24 skipped`).
- No mocks; real HTTP/SDK transport only (Chicago).
- No commits made.
