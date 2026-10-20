# Capability wave 2 — close-out prep (v26.10.19)

- **Date**: 2026-10-20
- **Subject**: smalt @ `1217df816341d18f496e5073351de8d1f89d41ab` (main; wave-1
  promotion commit), plus in-flight uncommitted lib edits disclosed below.
- **Context**: solo(docs lane, close-out prep)
- **Standing**: PREP — this file pre-registers the wave-2 close-out; no KD row
  here is closed or narrowed by this document. No code edits; no register
  edits (registrar-gated).
- **Authority**: KD rows quoted from
  `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md`; witness state from
  `scripts/kd_flip.py` dry-run at prep time (see §2); lane slugs are
  proposed, `_LANES.md` at wave-2 materialization is authoritative.
- **In-flight lib state at prep time** (uncommitted, on disk):
  `lib/smalt/application.ex` — deleted-bundle recovery prefixes
  (`/deletedkeys`, `/deletedsecrets`, `/deletedcertificates`) added to the
  twin/egress dispatch list (KD-117 twin-sync arm; PY wf6 LRO recovery rides
  the twin); `lib/smalt/policy.ex` — `enforcementMode`
  (DoNotEnforce|Default) persisted + echoed on policy assignments, and
  DoNotEnforce downgrades would-be deny verdicts to audit in
  `evaluate_assignment/2` (KD-112 enforcementMode arm).

## 1. Per-capability close-out table

| Capability | KD row(s) | Owning lane (proposed) | Evidence class | Close-condition command (falsifier) |
|---|---|---|---|---|
| KD-117 twin sync (deleted-bundle recovery planes reachable on the TLS twin) | KD-117 (fix-landed-partial → close) | kv-deletedkeys-twin | SDK probe cell — PY wf6 xfail recovery leg (deleted key/secret/certificate recover over the twin) flips to pass | `cd verification/py && python -m pytest -k "recover or deleted"` — the leg that was xfail-404 rides the new twin prefixes; TS mirror `cd verification/ts && node run.mjs` (wf4) |
| KD-112 enforcementMode + exemption close | KD-112 (OPEN; AZB-25c downcase landed `deb0795`, SDK-tier witness pending) | arm-policy | SDK/wire probe — active exemption exempts a deny (violating PUT → 201, not 400 PolicyViolation) AND DoNotEnforce assignment persists, echoes on GET, and never refuses | rerun `/tmp/kd112_probe2.sh` shape at SDK tier (`cd verification/ts && node run.mjs` arm leg or PY pytest `-k policy`); module-tier differential: mixed-case resource id + active exemption → `:ok` |
| blob.list JWT fix | none (parity fix, no registered divergence) | blob-suite | SDK probe cell — `list blobs` under the JWT/bearer credential path the SDK sends | `cd verification/ts && node run.mjs` (blob wf leg incl. list cell) — was failing auth face, flips green |
| cosmos accessor bypass + heir check | none (in-repo fix; v26.10.20 WO-3 shape) | cosmos-heir | Falsifier test — ru-limit transient state rides the `:heir`/accessor pattern; kill the owner, observe the value survives (or request retypes) | `MIX_BUILD_ROOT=_build-laneW2 mix test` (heir falsifier test green at pinned SHA); `cd verification/ts && node run.mjs` cosmos leg |
| KD-105 dispatch + flip | KD-105 (OPEN; shim `lib/smalt/data_plane/kv_pss.ex` mtime 2026-10-19T21:15:47; dry-run FLIP-PENDING-WITNESS) | kv-pss | External-verifier witness — Node `crypto.verify('sha256', digest, jwk, sig) === true`; PY hazmat mirror digest=true/message=false; witness receipt with embedded output, mtime > shim mtime | `cd verification/ts && node run.mjs` (wf4 sign leg) → witness receipt → `python3 scripts/kd_flip.py` dry-run FLIP-ELIGIBLE → kd-registrar `--apply` |
| KD-108 ACL wire + lease-on-snapshot arm | KD-108 (OPEN; shim `lib/smalt/data_plane/blob_storage.ex` mtime 2026-10-19T23:04:42; dry-run FLIP-PENDING-WITNESS) | blob-lease-acl | SDK probe cell — BlobLeaseClient acquire/renew/release + set/getAccessPolicy (ACL signed-identifier) roundtrip + lease-on-snapshot read-back | `cd verification/ts && node run.mjs` (blob lease/ACL cells) → witness receipt postdating 23:04:42 → flip |
| wf6 SKIP flips (PY `test_wf6_newcaps.py` + TS `newcaps.probe.mjs`) | aggregates several (enforcementMode, recovery xfail legs) | wf6-coverage | Suite cell flips — every SKIP/xfail in the wf6 files flips to pass or records a typed registered-divergence | `cd verification/py && python -m pytest test_wf6_newcaps.py` zero skip/xfail remaining; `cd verification/ts && node newcaps.probe.mjs` |
| KD-104 SDK witness | KD-104 (OPEN; witness `receipts/kd104-certificates-witness.md` 22:00 postdates `certificates.ex` 21:57, but see §2 token caveat) | kv-certificates | CertificateClient create/get SDK cell green, embedded output | `cd verification/ts && node run.mjs` (cert leg) → `python3 scripts/kd_flip.py` shows FLIP-ELIGIBLE once the KD-COVERS token lands → `--apply` |
| SB topics ARM surface | none (surface growth, no registered divergence) | sb-arm | Wire transcript — topics CRUD via ARM router (`/subscriptions/.../Microsoft.ServiceBus/namespaces/*/topics`) | topic create/list/delete transcript embedded in lane receipt; SDK cell where a suite leg exists |
| EH ARM consumer groups | none (no KD row) | eh-consumer-groups | Wire transcript — $management consumer-group ops | witness `receipts/v261019-c12-eh-consumer-groups.md` stands; close = re-witness at wave-2 HEAD if lib moved |
| cosmos SQL OFFSET/TOP | none (query-engine parity) | cosmos-query | SDK/wire probe — `OFFSET n LIMIT m` and `TOP` clauses return the correct paging faces | `cd verification/py && python -m pytest -k "offset or top"` / wire curl transcript; falsifier: wrong-row-count page fails |
| policy remediations | none (surface growth) | arm-policy (same lane, disjoint arm) | Wire transcript — remediation list/trigger face on an assignment with a deny | remediation transcript embedded in lane receipt; no register flip |
| KV key rotate data plane | none (surface growth) | kv-rotate | SDK probe cell — `rotateKey` returns the new version, old version still retrievable | `cd verification/ts && node run.mjs` (kv wf4 rotate cell) |
| appconfig snapshots | none (surface growth on the KD-53 plane) | appconfig-snapshots | Wire transcript — snapshot create/list + read-back via the `/kv` App Configuration face | snapshot roundtrip transcript in lane receipt; PY/TS cell if the suite covers it |
| sentinel multi-table | KD-22's plane (row already CLOSED-SIMULATED; no new flip) | sentinel | Wire transcript — multi-table ingestion/query on the sentinel face | multi-table transcript in lane receipt; no register action (KD-22 already closed) |
| MCP wave-2 tools | none (surface growth) | mcp-tools | Generated-descriptor diff + probe call transcript | descriptor regen via `ggen_igniter.sync` (never hand-edit `lib/smalt/mcp/generated/mcp_descriptor.ex`) + probe call green in lane receipt |
| diagnostics TS+PY coverage | none (coverage parity) | diagnostics-coverage | Suite cells — diagnostics/logs surfaces mirrored in both external suites | `cd verification/ts && node run.mjs` + `cd verification/py && python -m pytest` diagnostics cells green, parity noted |

Rows with no KD id are new capability, not divergence closure — their close
receipts stand alone and they never enter `kd_flip.py`. If any surfaces a real
divergence, that is a registrar mint, not a unilateral one.

## 2. Registrar flip plan (kd_flip eligibility law)

Flips only via `scripts/kd_flip.py` (dry-run default; `--apply` after the fin
sweep, before wrap regeneration). Dry-run at prep time (2026-10-20):

```
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 2
  KD-105: no post-shim receipt newer than shim mtime (2026-10-19T21:15:47)
  KD-108: no post-shim receipt newer than shim mtime (2026-10-19T23:04:42)
```

| KD row | Shim carrier (KD-COVERS site) | Flip witness (must postdate shim mtime, show PASS) | Registrar verdict |
|---|---|---|---|
| KD-105 | `lib/smalt/data_plane/kv_pss.ex` (`kv_pss.ex:5`) | external crypto.verify witness with embedded output, mtime > 21:15:47 2026-10-19; wave-1's `kd105-ps256-external-verify-tbd.md` (19:34) predates the shim and does NOT count | dry-run → `--apply` on FLIP-ELIGIBLE |
| KD-108 | `lib/smalt/data_plane/blob_storage.ex:2042` | blob lease/ACL SDK cell green, mtime > 23:04:42 2026-10-19 (`kd108-blob-lease-acl-tbd.md` 20:15 predates — does not count) | same |
| KD-104 | `lib/smalt/data_plane/certificates.ex` — **NO KD-COVERS token present** (not in the 35-id covers-map). The 22:00 witness postdates the 21:57 file mtime but the tool cannot see the pairing | (1) owner/code lane adds `# KD-COVERS: KD-104` to `certificates.ex`; (2) witness receipt postdates the token-bearing file's new mtime — likely a re-witness; (3) then flip | token-first, then dry-run → `--apply` |
| KD-117 | no KD-COVERS token (`egress_router.ex`/`application.ex` arms carry no KD-117 token) | same pattern: token lands with the twin-sync arm, witness (PY wf6 recovery leg green) postdates it | same |
| KD-112 | no KD-COVERS token on the enforcementMode/exemption arms | exemption-active witness (violating PUT → 201) + DoNotEnforce echo witness postdating the `policy.ex` mtime once tokenized | same |

This document RE-OPENS the wave-1 vacuity channel: the tool counts "a newer
file under the receipts dir mentioning the id", and this prep doc names
KD-105/KD-108/KD-117/KD-112/KD-104. **The registrar must NOT flip any row on
this document** — it carries no embedded PASS output and is not a witness.
Eligibility must be re-read dry-run after each lane's real witness receipt
(embedded falsifier output, `Context:` line) lands; only rows the dry-run
shows FLIP-ELIGIBLE against their true witnesses flip.

Sequencing: (1) lanes land shims carrying `# KD-COVERS: KD-nn` (KD-104,
KD-117, KD-112 token obligations noted above); (2) witnesses land with
embedded output, postdating each shim mtime; (3) `python3 scripts/kd_flip.py`
dry-run — every wave-2 flip row FLIP-ELIGIBLE, any UNKNOWN-KD is an exit-1
register-sync obligation; (4) kd-registrar `--apply` after the fin sweep;
(5) regenerate RECEIPTS/SDK_MATRIX (`just receipt-index` / `just
sdk-matrix-md`) — never hand-edit.

## 3. Wrap obligations carried

- **court-x2 at wave HEAD**: after flips, two consecutive `just court` greens
  at one pinned wave-2 SHA (`just quiet-check` first; `just quiesce` when the
  machine was busy — both wave-1 court-x2 attempts failed cold run 1, passed
  warm run 2). Run 2's log feeds the release-receipt mint; precedent:
  `receipts/v261019-12-court-x2-close.md` (court-x2 #3).
- `just docs-dod-check` must pass — every receipt path named in this file and
  in wave-2 lane receipts must exist on disk.
- `just publish-dry` before FINAL wrap.
- No GAP tokens minted unilaterally; typed-UNSUPPORTED pins go through
  WIRE_PARITY.md registrar discipline.
- Coordinator deletes all lane build roots (`_build-lane*`) at integration
  before the final commit.
