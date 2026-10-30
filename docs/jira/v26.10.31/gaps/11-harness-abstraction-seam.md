# 11a Harness Abstraction Seam — Design (category (c) plan, NOT implemented)

Status: **ALIVE (design-only)** — spec shard for posh lane 11
(`docs/jira/posh/v26.10.31/gaps/11-harness-coupling.md`). Code (`test/**`,
`apps/web`) is BLOCKED for this lane; harness lanes own it. This shard is the
category (c) plan that empties it, grounded in the actual 24 files / 3,022
lines of `apps/web/test/harness/` (re-verified this session: `wc -l` over all
24 files = 3,022 total, exact).

## Seam interface (what the neutral harness needs)

Five operations plus one pure function. Every dialect-specific concern in the
harness today reduces to one of these; nothing else is dialect-coupled.

1. **`substrateUp(): Promise<boolean>`** — liveness probe + loud-skip gate.
   Today: two copies (lib/smalt-client.ts:53-63 `fetch(SMALT_BASE +
   "/metadata/endpoints")`; vault/lib.ts `planeUp`, same endpoint against
   `SMALT_PLANE` with a distinct default). The seam unifies endpoint
   resolution (today vault/lib.ts:6 reads `SMALT_PLANE` only, so `SMALT_BASE`
   alone never reaches the vault suites — a real drift bug the seam removes)
   and the timeout shape.
2. **`bootSubstrate(): Promise<Substrate>`** — boot/teardown lifecycle.
   Today implicit: setup.ts:11 `await probeOnce()` only sets
   `process.env.SMALT_SUBSTRATE`; teardown is "suites own cleanup" per
   setup.ts:4 comment. The seam makes it an explicit
   `Substrate { base, plane, tenantId, subscriptionId, stop() }` handle
   instead of a bare boolean plus env side effects.
3. **`portEnv()`** (pure) — env → endpoints resolution. Today env names split
   three ways: `SMALT_BASE` (smalt-client.ts:3, version.test.ts:30,
   perf.test.ts:100, ux-001:85/96, lib/concurrency.ts:56),
   `SMALT_PLANE` (vault/lib.ts:6, vault-001:24 skip message),
   `SMALT_SUBSCRIPTION_ID` (lib/residue.ts:7). After migration the seam is the
   single reader of these; the only harness file still touching
   `process.env` for plane addressing would be nfr/hermetic.test.ts:56, which
   legitimately forwards env to a child process.
4. **`mintToken(scope?): Promise<string>`** — STS mint. Today: two full copies
   (smalt-client.ts:8-21; vault/lib.ts:41-70 with its own TTL cache) plus
   `mintTokenCached` (smalt-client.ts:31-40) and version/lib.ts's armRetry
   wrapper (line 20). The seam owns minting + caching; consumers never see a
   bearer string or the path split `/smalt/oauth2/v2.0/token`
   (smalt-client.ts:12) vs `/{tenant}/oauth2/v2.0/token` (vault/lib.ts:50),
   nor the duplicated `smalt-sovereign-mock-secret` literal
   (smalt-client.ts:16, vault/lib.ts:57).
5. **`arm(op, path, body?, opts?)`** — transport: bearer injection, JSON
   encoding, `ArmResponse { status, body, text, headers }`. All 24 files'
   dialect surface reduces to the `path` string (ARM paths + api-version
   query params). After migration the ONLY dialect residue in the harness is
   path/api-version strings, which the dialect layer owns wholesale.
   version/lib.ts armRetry (line 20) becomes a seam option
   (`arm(..., {retries})`), not a wrapper file.
6. **`assertReceiptHeader(headers): ReceiptRef`** — receipt fence assertion.
   Today: `TURNSTILE_HEADER` + `captureReceipt` (lib.ts:14, 47-60) plus the
   raw `headers.get("x-smalt-receipt-turnstile")` literals in
   vault/tc-vault-003:37-45. The seam is the single place that knows the
   header name and the 64-hex digest law; tc-vault-003 keeps its core
   assertion (this is the (b) receipt fence per lane 14's neutrality finding)
   but stops spelling the header literal.

## Which of the 24 files consume the seam — per-file verdicts

Classes re-checked by grep this session against the same evidence lines the
gap doc cites. A = full consumer (assertion bodies byte-identical, transport
swapped); B = partial consumer (addressing only); C = non-consumer
(untouched).

| # | File | Lines | Class (gap doc) | Verdict | Ops consumed | Grounding |
|---|---|---|---|---|---|---|
| 1 | `setup.ts` | 23 | (a) shared | A | bootSubstrate | imports substrateUp (line 2), `probeOnce()` at 11 sets `SMALT_SUBSTRATE` env — contract preserved so suites' loud-skip gates keep working |
| 2 | `lib.ts` | 109 | (a) shared | A (partial) | assertReceiptHeader | TURNSTILE_HEADER/captureReceipt (14, 47-60) move to seam; auditEvent/sha256Hex + probeAmqp (66-109) are dialect-agnostic socket work and stay harness-utils |
| 3 | `lib/smalt-client.ts` | 80 | (a) shared | Becomes the seam | all | this IS the seam's neutral driver: endpoint (3), mint (8-21), cached mint (31-40), arm (43-62), probe (53-63) |
| 4 | `lib/concurrency.ts` | 73 | (b) | A | arm, portEnv | its own `fetch(SMALT_BASE...)` copy at line 56 is a fourth transport duplicate — absorbed |
| 5 | `lib/residue.ts` | 233 | (b) | A | arm, portEnv | imports arm/mintToken (line 4), own `SMALT_SUBSCRIPTION_ID` read (7), arm sites 22-23/118/144/195; h10-* residue GET is ARM wire as transport, assertion untouched |
| 6 | `tenant/tenant.test.ts` | 100 | (a) | A | arm, mint, probe | import line 2; arm sites 24/36/41/45/47/63/65/70/82/96 |
| 7 | `container/container.test.ts` | 178 | (a) | A | arm, mint, probe | import line 6; 14 arm sites 57-160 |
| 8 | `vault/lib.ts` | 220 | (a) | A (hardest collapse) | all five ops | duplicate transport: PLANE (6), mint (41-70), arm (67+); MissingSecretError/SmaltPlaneError stay suite-owned — only the transport deletes |
| 9 | `vault/tc-vault-001-retrieval.test.ts` | 63 | (a) | A (inherited) | via vault/lib.ts | SKIP message reads SMALT_PLANE at line 24 → portEnv |
| 10 | `vault/tc-vault-002-fail-closed.test.ts` | 53 | (a) | A (inherited) | via vault/lib.ts | typed 404 law asserted through vault/lib helpers |
| 11 | `vault/tc-vault-003-receipt-header.test.ts` | 49 | (b) | A (partial) | assertReceiptHeader | turnstile header literals at 37-45 move to seam op 6; the 64-hex fence assertion itself survives byte-identical (gap doc verdict item 3) |
| 12 | `crmh/lib.ts` | 147 | (a\|b) | B | portEnv, arm (live legs) | own fetch at line 131; offline schema-law legs stay neutral |
| 13 | `crmh/crmh.test.ts` | 160 | (a\|b) | B | via crmh/lib.ts | (b) blobPath schema-law legs byte-identical; (a) live legs via seam |
| 14 | `version/lib.ts` | 183 | (a) | A | arm, portEnv | CEILINGS table (33-47) and armRetry (20) — retry becomes seam option; CEILINGS stays suite-owned (it IS the dialect subject) |
| 15 | `version/version.test.ts` | 171 | (a) | A | arm, portEnv | SMALT_BASE read at 30; api-version ladder legs via version/lib |
| 16 | `siem/wire.test.ts` | 94 | (a) | A | arm, assertReceiptHeader | import 6-8; arm 24/32/77; TURNSTILE reads 46/55 |
| 17 | `siem/audit-event.test.ts` | 86 | (b) | C | none | offline auditEvent legs, zero wire — survives untouched |
| 18 | `ux/lib.ts` | 163 | (b) | B | portEnv only | fetchWithSla (31-50) is dialect-neutral; collaborator is the caller's URL |
| 19 | `ux/tc-ux-001-sla.test.ts` | 102 | (b) | A (partial) | portEnv | SMALT_BASE import (10) used at 85/96 only for the happy-path plane leg; SLA legs run against a real local createServer (22-53) |
| 20 | `ux/tc-ux-002-diagnostics.test.ts` | 75 | (b), dialect-pinned fixtures | C | none | formatSubstrateError logic neutral; fixtures are REAL captured refusal bodies — re-capture if dialect changes (gap doc flag) |
| 21 | `nfr/cleanup.test.ts` | 202 | (b) | A | arm, mint, probe | import line 6 |
| 22 | `nfr/concurrency.test.ts` | 152 | (b) | A | arm, portEnv | via lib/concurrency.ts:56 |
| 23 | `nfr/hermetic.test.ts` | 142 | (b) | C (by design) | none | probes PUBLIC ARM URL (management.azure.com, line 24) — intentionally outside the local seam; env forwarded to child at 56; its endpoint literals are the one behavioral blast radius (gap doc item 4) |
| 24 | `nfr/perf.test.ts` | 164 | (b) | A | arm, mintTokenCached, portEnv | mint hit-path assert (10, 26) maps to seam cached mint; own SMALT_BASE read at 100 |

Tally: A full/partial consumers = 17 files (1,2,3,4,5,6,7,8,9,10,11,14,15,16,19,21,22,24 — 18 counting smalt-client itself as the seam); B partial = 4 (12,13,18 and vault-001's env read folds into 8's entry); C = 3 (17, 20, 23). Precise: A=16 files, B=3, C=3, seam itself=1, plus vault-001/002 counted within A-inherited.

## Migration order (post-strip)

Strip = the harness lanes' pending dialect-strip pass over `test/**`. After
it lands, in order:

1. **Extract the seam from `lib/smalt-client.ts` in place** (no new module):
   formalize substrateUp/bootSubstrate/portEnv/mintToken(+cache)/arm/
   assertReceiptHeader with the exact signatures above. smalt-client.ts is
   already the de facto seam (gap doc: "the natural seam ... (c) lives here,
   not in the suites"); extraction is a rename + typing pass, zero behavior
   change.
2. **Collapse the duplicate transports** in vault/lib.ts and
   lib/concurrency.ts onto the seam (steps 2-3 of the diff; each is a
   delete-only change minus the typed-error contracts, which stay).
3. **`setup.ts` switches to bootSubstrate**; `SMALT_SUBSTRATE` env contract
   preserved so all loud-skip gates (vault-001:24, siem/wire:40/85,
   ux-001:90) keep their evidence strings.
4. **Convert consumers in dependency order**: leaf utils first
   (lib/residue.ts, lib/concurrency.ts) → vault/lib.ts (unblocks 9/10/11) →
   suites with no suite-local transport (6,7,16,21,22,24,15) → version/lib.ts
   (armRetry → seam retry option) → partials last (12,13,18,19).
5. **Then, and only then, the dialect-surface move**: path/api-version
   strings are the sole remaining dialect residue; they move to the dialect
   layer as data (the CEILINGS-style tables), which is the point at which
   category (a) suites reclassify to (c) consumers of an abstraction rather
   than dialect-speakers.
6. **Guard**: nfr/hermetic.test.ts stays a non-consumer; when the dialect
   layer lands, its public-endpoint literals (line 24, guard script
   `scripts/hermetic_guard.sh`) get revisited per gap doc item 4 — the only
   place the seam migration has behavioral blast radius.

## Falsifier receipt (this session)

- `wc -l` over `find apps/web/test/harness -name '*.ts'` = exactly 24 files,
  3,022 total — matches gap doc headline. EXACT.
- Per-file existence: all 24 paths in the verdict table were read or grep'd
  this session; every cited line number comes from this session's output
  (no line number is carried over from the gap doc unread).
- Classification re-checks: tenant/container/vault/siem-wire import
  arm/mintToken from smalt-client (dialect transport) — confirmed; vault-003,
  audit-event, ux-001 local-server legs, hermetic public-URL legs —
  confirmed (b)/neutral as classified.
- New finding vs gap doc: **env drift bug** — vault/lib.ts:6 reads only
  `SMALT_PLANE` while 10+ other files read `SMALT_BASE`; pointing SMALT_BASE
  at a non-default port silently strands the three vault suites. The seam's
  portEnv (op 3) closes this by construction.

## Status

ALIVE (design-only). Lease honored: gap doc + this shard are the only files
this lane touches; `apps/web`/`test/**` untouched.
