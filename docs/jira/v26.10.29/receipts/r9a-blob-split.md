# r9a — blob split (T09: BlobStorage 3,444 → Blob.Core/Worm/Leases/Website)

- window: v26.10.29 · date: 2026-10-30 · lane: L09
- subject: smalt @ 35bd36d0 (shared tree heavily dirty — 47+ sibling-lib files
  in flight during this window; this lane touched ONLY its ownership set)
- standing: **ALIVE (engine-direct) / PARTIAL (wire row)** — all four faces
  extracted and gated; every L09 gate cycle introduced zero new court
  failures; the blob-worm wire gate row stays FAIL from a pre-existing
  sibling egress-split misroute (same signature before and after every
  L09 change; see Gate receipts).

## What landed

Ownership files only. Prior attempt landed nothing (rate-limit death);
started fresh — `lib/smalt/data_plane/blob/` verified absent first.

| file | lines | sha256-16 |
|---|---|---|
| lib/smalt/data_plane/blob_storage.ex | 161 | 5157d711d905f521 |
| lib/smalt/data_plane/blob/core.ex | 1879 | ddc3961f2fe6a3be |
| lib/smalt/data_plane/blob/worm.ex | 636 | a8b8fc513b930222 |
| lib/smalt/data_plane/blob/leases.ex | 714 | 7db2f54c07d1c1ec |
| lib/smalt/data_plane/blob/website.ex | 257 | b1ba193b628b6f0d |

- BlobStorage = thin facade now: moduledoc + aliases + 61 defdelegates.
  Public API byte-identical (name/arity/defaults); wire behavior unchanged.
- Blob.Core — container/blob CRUD, blocks, snapshots, metadata/append/page,
  listing XML, ACL, shared engine helpers (now_ms, container_key, request_id,
  rfc1123, header_value, xml_text, xml_escape, blob_or_404, put_*_record).
- Blob.Worm — immutability policy + legal hold CRUD, WORM arm resolver
  (create/overwrite/delete), per-blob immutability, serialized policy CAS.
  Fail-closed surface; the WORM probe (below) is its non-vacuity court.
- Blob.Leases — container/base-blob/snapshot leases (KD-107/108), ETag +
  conditional request helpers, ranged GET + conditional read engines.
- Blob.Website — static-website face (service properties, $web serving).

Moved code is verbatim: each cycle was an anchor-based mechanical transform
with counted assertions, plus a VERIFY mode that recomputed both output
files from the pre-cycle sha256 snapshot and byte-compared them to disk
(`cmp` → CORE/FACADE/WORM/LEASES BYTE_EXACT receipts in the session log).
Only declared deltas: defp→def on cross-module helpers, `BlobStorage.`
qualifications on moved call sites, defdelegate shims.

## Gate receipts (real output, per cycle)

Runner: bounded-poll compile-green (20s interval, 6 min deadline) → 10 blob
court files → `python3 scripts/invariant_gates.py --gate blob-worm`
(isolated blob row; runner does not honor MIX_BUILD_ROOT for its own python
but the substrate boot inherits it via `env = dict(os.environ)` in
gates/common.py:36 — verified by reading the source). All runs
`MIX_BUILD_ROOT=_build-l09`, pinned asdf toolchain
(elixir 1.20.4-otp-29 / OTP 29.1.2), private SMALT_TEST_* port pins.

Court census (same 10 files each run):

| run | failed | delta vs prior | attribution |
|---|---|---|---|
| c0 baseline (pre-edit) | 27 | — | sibling egress-split misroute era |
| c1 +Website | 23 | 4 flipped PASS, 0 new | sibling fixes (egress/KV/website wire) |
| c2 +Worm | 21 | 2 flipped PASS, 0 new | sibling fixes; KD-140 leg shuffle |
| c4 full split | 21 | census == c2 except KD-140 leg shuffle | sibling churn only |

c4 courts tail (real): `COURTS_EXIT=2 :: Failed: 21 tests` — compile
`COMPILE_GREEN (attempt 0)`.

blob-worm wire gate: FAIL in every run INCLUDING the pre-edit baseline,
one stable signature — positive leg `blob written -> 404` (the egress
split's subrouter fall-through misroutes blob PUT before the engine is
reached; courts log shows `egress subrouter ... falling through` warnings).
Receipt `tmp/invariant-gates/blob-worm-receipt.json`: verdict FAIL,
positive FAIL. This row is red because of the sibling egress face, not the
blob engine; it is the standing falsifier — it should flip green when the
egress lane lands the blob subrouter, with the split in place.

Engine-direct WORM probe (churn-immune non-vacuity court; real engine +
real Store ETS, no mocks; `/tmp/l09/worm_engine_probe.exs` via `mix run`).
Final full-split run (2026-10-30, PROBE_EXIT=0):

    PASS create+write
    PASS hold refuses overwrite+tier+snapshot+delete
    PASS release restores delete; snapshot-of-missing 404s
    PASS per-blob immutability refuses overwrite+delete
    PASS extension admitted; mode-without-date 400

The hold legs drive `BlobStorage.put_blob/set_blob_tier/snapshot_blob/
delete_blob` → facade → Core → `Worm.worm_blocked?/3` — the exact call
sites of the L14 unblock (next section), re-verified green post-split.

## Cross-lane disclosures (both-receipt rule)

- L14 SLA unblock INTO this lane's file (~23:22, while the facade was
  compile-frozen past the 10-min window): (1) four `\` → `\\` defdelegate
  default-arg typos; (2) qualification of six `worm_blocked?(` call sites
  to the public `Worm.worm_blocked?/3` (a genuine c2 miss of this lane —
  acknowledged). Both re-verified in the final gate: compile green, probe
  hold legs green. Mirror-disclosed here per the rule; L14 carries the
  same disclosure in r10c-tail-a.md.
- This lane's own transient freezes, fixed forward: c3 delegate
  backslashes (self-caught before any green run depended on them),
  leases.ex missing `header_value/2`/`ensure_snapshot_table/0`
  qualifications, core.ex tail `end` + mixed def/defp visibility on
  `header_value/2`, missing `alias Blob.Core` on the facade.
- Sibling churn witnessed (never touched by L09, all self-healed by their
  owners): key_vault/hsm.ex (22:19), purview_atlas/glossary.ex (22:19),
  saml_idp.ex, oidc_authorize.ex, appconfig_tenant.ex (~00:0x).

## Pre-existing vs session-introduced

- The 21-27 court failures and the blob-worm gate FAIL predate L09's first
  edit (c0 baseline, untouched tree) and match r0-baseline's RED
  integration tier. Root signature (subrouter fall-through) belongs to the
  in-flight egress split. Census diffs across all L09 cycles show zero
  L09-attributable failures.
- Session-introduced and fixed before receipt: the freezes disclosed above
  (each caught by compile or the transform assertions; no court run
  reported a false green through any of them).

## Remaining work

- Wire-row flip: blob-worm gate + KD-135/137/139/66/67 courts should go
  green when the egress face lands the blob subrouter (their lanes).
- Optional polish (not required by T09): facade keeps D127/AR-WIRE header
  comments as historical pins; unused BlobService/ConditionalHeaders/Store
  aliases remain on the facade (warning-free, retained for review ease).
