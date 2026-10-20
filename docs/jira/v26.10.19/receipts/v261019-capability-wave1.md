# Capability wave 1 — close-out prep (v26.10.19)

- **Date**: 2026-10-19
- **Subject**: smalt @ `deb079520e886aedee0d680eed228060c6925d6e` (main)
- **Context**: solo(docs lane)
- **Standing**: PREP — this file pre-registers the close-out; no KD row here is
  closed or narrowed by this document. No code edits; no register edits
  (registrar-gated).
- **Authority**: KD rows quoted from
  `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md` (rows KD-99..KD-119); close
  conditions and falsifiers are that table's, restated. Lane slugs are the
  wave's capability slugs; `_LANES.md` at materialization is authoritative.
- **In-flight lib state at prep time** (untracked, on disk):
  `lib/smalt/data_plane/certificates.ex` (KD-104), `lib/smalt/data_plane/kv_pss.ex`
  (KD-105/KD-119), `lib/smalt/event_grid_webhook.ex` + `test/internal/event_grid_webhook_test.exs`
  (KD-101); modified: `key_vault_actions.ex`, `vault_data.ex`, `purview_atlas.ex`,
  `queue_store.ex`, `arm_gateway/router.ex`.

## 1. Per-capability close-out table

| Capability | KD row(s) | Owning lane | Expected evidence class | Close-condition command (falsifier) |
|---|---|---|---|---|
| KV deleted-keys plane | KD-117 (narrow→close), KD-102 (sibling face) | kv-deletedkeys (WO-1d) | both — wire transcript (list/get deleted face, recover) + SDK probe cell (TS wf4) | `cd verification/ts && node run.mjs` — delete → getDeletedKey → recoverDeletedKey → get roundtrip green in the leg that was 404×2; PY mirror `cd verification/py && python -m pytest -k deleted` |
| Secrets backup/restore | KD-103 | kv-secrets-bk | both — backup-blob roundtrip transcript + SDK cell (TS wf4 / PY mirror) | backup → restore roundtrip green: `cd verification/ts && node run.mjs` (wf4 leg); falsifier flips the leg that was a typed refusal |
| Certificates plane | KD-104 | kv-certificates | both — cert create/get wire transcript + `CertificateClient` SDK cell | CertificateClient create/get green: `cd verification/ts && node run.mjs` (cert leg) |
| PS256 external verify | KD-105 (with KD-119 single-hash fix as sibling) | kv-pss (lib/smalt/data_plane/kv_pss.ex) | both — crypto.verify transcript + SDK sign cell | Node `crypto.verify('sha256', digest, jwk, sig) === true`; PY: hazmat verify digest=true/message=false — `cd verification/py && python -m pytest -k "ps256 or sign"` |
| scheduleMessage | KD-118 | sb-schedule (WO-1e) | SDK probe cell — schedule → deliver-at-time → receive+complete | `cd verification/ts && node run.mjs` (SB wf3 leg); if typed-UNSUPPORTED pinned instead, WIRE_PARITY token + KD row stays OPEN-pinned |
| EG webhook-receiver surface | KD-101 (narrowed — surface exists, push path) | eg-webhook (lib/smalt/event_grid_webhook.ex) | both — handshake+delivery wire transcript + internal-tier test | subscriber endpoint receives delivered CloudEvent; internal gate: `mix test test/internal/event_grid_webhook_test.exs`; wire: handshake validation transcript in receipt |
| Blob snapshot listing + lease-raises | KD-107 (remainder), KD-108 (remainder) | blob-snap-lease | SDK probe cell — snapshot list + read-back, lease acquire/renew/release, ACL roundtrip | `cd verification/ts && node run.mjs` (blob leg list/lease cells) |
| Policy RBAC scopes + real locks | KD-113 legs 1-2 | arm-policy-rbac | SDK probe cell — role assignment at arbitrary scope, lock CRUD as real records | `cd verification/ts && node run.mjs` (arm leg) + `cd verification/py && python -m pytest -k "rbac or lock"` |
| Tags-at-scope | KD-113 leg 3 | arm-policy-rbac (same lane, disjoint falsifier leg) | SDK probe cell — tag-at-scope roundtrip | `cd verification/ts && node run.mjs` (arm tag-at-scope cell) |
| LRO widening | KD-111 | arm-lro | SDK probe cell — poller 202 → terminal per covered route | `cd verification/ts && node run.mjs` (arm LRO poller cell) |
| SKR envelope | KD-106 | kv-skr | both — release-blob contract transcript + SDK release flow cell | SDK release flow receives well-formed release payload; `cd verification/ts && node run.mjs` (kv release leg) |
| Atlas raise | none (no KD row — GA-parity raise, no registered divergence) | purview-atlas (purview_atlas.ex modified) | wire transcript — the raised op answers per Azure face | op transcript embedded in lane receipt; falsifier re-run on revert must fail |
| KQL raise | none (no KD row) | purview-atlas (same lane) | wire transcript | same as Atlas raise |
| MCP new read-only tools | none (no KD row — surface growth) | mcp-tools | both — generated-descriptor diff + probe call transcript | descriptor regen (`ggen_igniter.sync`) + probe call green in lane receipt |
| Throttle profiles | KD-110 | throttle-profiles | both — 429+Retry-After transcript + over-limit probe cell | over-limit probe receives 429 with Retry-After: `mix test` throttle cell + probe transcript |
| Cosmos container/db DELETE cascade | none (no KD row — semantics parity) | cosmos-cascade | wire transcript — delete db cascades collections; docs + tombstones | cascade transcript in lane receipt; falsifier: orphaned collection post-delete must 404 |
| EH consumer-group engine | none (no KD row) | eh-consumer-groups | wire transcript — $management consumer-group ops | create/list/delete consumer-group transcript in lane receipt |
| SB deferred/settle ops | none (no KD row — receiveDeferred/settle family) | sb-deferred | wire transcript + SDK cell where a suite leg exists | receiveDeferred → complete roundtrip; `cd verification/ts && node run.mjs` (wf3 leg if covered) |
| wf6 coverage cells (TS+PY mirrors) | aggregates KD-101..113 cells | wf6-coverage | SDK probe cells — TS+PY mirror parity per cell | TS: `cd verification/ts && node run.mjs`; PY: `cd verification/py && python -m pytest` — cell-by-cell parity table in wf6 receipt |

Rows with no KD id raise parity without narrowing any register row; their
close receipt stands alone. If any of them surfaces a real divergence, that is
a registrar mint, not a unilateral one.

## 2. Registrar flip plan (kd_flip eligibility law)

Flip mechanism is `scripts/kd_flip.py` only — read-only dry-run by default,
`--apply` mutates `KNOWN_DIVERGENCES.md` (OPEN → CLOSED-SIMULATED) exclusively
for rows where **a PASS witness receipt's mtime postdates the newest shim
mtime** covering that KD id (`# KD-COVERS: KD-nn` token in the `lib/` shim, or
covers-map presence). No receipt newer than the shim, no flip
(FLIP-PENDING-WITNESS). Unknown ids never flip; exit 1 forces register sync
for any KD-COVERS token whose id is missing from the register.

Per-row flip gates (registrar runs dry-run first, `--apply` only on
FLIP-ELIGIBLE):

| KD row | Shim carrier (KD-COVERS token site) | Flip witness (must postdate shim mtime, show PASS) | Registrar verdict |
|---|---|---|---|
| KD-117 | `lib/smalt/data_plane/key_vault_actions.ex` deleted-keys arm | wf4 TS deleted-keys cell green x1 post-shim (prior 404×2 witnesses predate) | dry-run → `--apply` on FLIP-ELIGIBLE |
| KD-102 | `lib/smalt/data_plane/vault_data.ex` secrets soft-delete arm | wf4 TS getDeletedSecret/recover roundtrip green post-shim | same |
| KD-103 | backup/restore arm (key_vault_actions.ex) | backup→restore roundtrip cell green post-shim | same |
| KD-104 | `lib/smalt/data_plane/certificates.ex` | CertificateClient create/get cell green post-shim | same |
| KD-105 | `lib/smalt/data_plane/kv_pss.ex` | Node crypto.verify true post-shim (PY hazmat mirror) | same |
| KD-119 | `lib/smalt/data_plane/kv_pss.ex` (single-hash fix) | hazmat verify digest=true post-shim (wf4-py leg flips) | same |
| KD-118 | SB scheduleMessage arm (queue_store.ex arm) | schedule→deliver→receive cell green post-shim; else stays OPEN-pinned typed-UNSUPPORTED (no flip) | flip only on implemented-op witness |
| KD-101 | `lib/smalt/event_grid_webhook.ex` | subscriber-receives-CloudEvent witness post-shim | same |
| KD-107/KD-108 remainders | blob snapshot-list / lease-ACL arms | respective blob cells green post-shim | same |
| KD-113 (all legs) | arm router/policy arms | role-scope + lock + tag-at-scope cells green post-shim | per-leg receipts, one row flip when all three witness |
| KD-111 | LRO widening arm | poller 202→terminal on newly covered routes post-shim | same |
| KD-106 | SKR envelope arm | release-blob contract witness post-shim | same |
| KD-110 | throttle profile arm | 429+Retry-After witness post-shim | same |

Rows with no KD id (Atlas/KQL raises, MCP tools, cosmos cascade, EH
consumer-groups, SB deferred, wf6 mirrors) have **no flip** — they are new
capability, not divergence closure. They never enter the covers-map and never
enter `--apply`.

**Vacuity disclosure (measured, this file)**: `python3 scripts/kd_flip.py`
dry-run at prep time reports FLIP-ELIGIBLE for KD-105 and KD-111 citing THIS
file as witness — because the tool counts "a newer file under the receipts dir
mentioning the id", and this prep doc names every wave id. This file carries
no embedded PASS output; it is not a witness. The registrar must NOT flip
KD-105/KD-111 (or any row) on this document — eligibility must be re-read
after this file is excluded or superseded by the lane's real witness receipt
with embedded falsifier output.

Sequencing: (1) each lane lands its shim carrying `# KD-COVERS: KD-nn`;
(2) lane or rewitness lane runs the falsifier and lands the witness receipt
(`Context:` line per the receipt-context law); (3) `python3 scripts/kd_flip.py`
dry-run — every wave row must show FLIP-ELIGIBLE or FLIP-PENDING-WITNESS, any
UNKNOWN-KD is an exit-1 register-sync obligation; (4) kd-registrar runs
`--apply` after the fin sweep, before wrap regeneration; (5) regenerate
generated docs (RECEIPTS/SDK_MATRIX via `just receipt-index` / `just
sdk-matrix-md`) — never hand-edit.

## 3. Wrap obligations carried

- court-x2 at one pinned SHA after flips (`just quiet-check` first).
- `just docs-dod-check` must pass — every receipt path named here and in lane
  receipts must exist on disk.
- No GAP tokens minted unilaterally; typed-UNSUPPORTED pins go through
  WIRE_PARITY.md registrar discipline.
