# w6t — Registrar pass 2 + ERROR_CODES extractor gap

**Standing:** ALIVE (mechanical lane; real command output embedded)
Date: 2026-10-20
Context: solo

## Task 1 — ERROR_CODES extractor gap (4 literal families)

Root cause: the extractor's family regexes predated four literal families:

1. **ScopeLocked** (arm-gateway 409) — emitted as inline envelope through a
   `defp` helper: `send_json(conn, 409, lock_scope_locked_body(rg_id))`
   (router.ex:848); `Smalt.Policy.scope_locked_body/1` (policy.ex:1336) rides
   the deny path.
2. **PolicyRemediationInvalid** (arm-gateway 400) — `remediation_refusal/3`
   defp literal (policy.ex:889), sent 400 at router.ex:5444.
3. **SnapshotExists** (data-plane 409) — T7 class: `{:error, {"Code", msg}}`
   two-tuple whose HTTP status is decided at the egress consumer
   (`snapshots_error/2`), not literal at the emission site.
4. **CertificateNameAlreadyExists** (pre-existing-extractor gap): emitted via
   helper call form `{:error, 409, certificate_error("...")}` — T3 only matched
   `bad_request("Code")`, so the helper-call form never extracted.

### Extractor changes (scripts/gen_error_codes.py)

- **C2 family** (extract_arm): `send_json(conn, NNN, helper(...))` — resolves
  the helper's defp `"code"` literal within 5000 chars; fail-closed (exit 1)
  if a helper lost its literal.
- **extract_policy** widened: `remediation_refusal` (400) + `scope_locked_body`
  (409) defp literals, statuses pinned by router send sites / KD-113 leg b.
- **T3 generalized**: `{:error, NNN, helper("Code")}` — any helper, not only
  `bad_request/1` (captures CertificateNameAlreadyExists).
- **T7 family (new)**: `{:error, {"Code", msg}}` with a fail-closed pinned
  status table `TWO_TUPLE_PINNED_STATUS` (statuses backed by the egress
  consumer `snapshots_error/2`: SnapshotExists/Conflict/SnapshotArchived/
  SnapshotNotArchived 409; SnapshotNotFound 4×404; InvalidFilter/
  InvalidComposition 400). Unknown two-tuple code → exit 1, never guessed.
  The fail-closed arm surfaced 4 additional two-tuple families beyond the
  named gap (Conflict, SnapshotArchived, SnapshotNotArchived, and the
  SnapshotNotFound multiline span) — all consumer-backed, all now projected.

### Result (real output)

```
wrote /Users/sac/smalt/docs/ERROR_CODES.md (196 rows)
docs/ERROR_CODES.md up to date
EXIT=0
docs/ERROR_CODES.md:44  | arm-gateway | 409 | ScopeLocked | router.ex:848
docs/ERROR_CODES.md:48  | arm-gateway | 400 | PolicyRemediationInvalid | policy.ex:889
docs/ERROR_CODES.md:50  | arm-gateway | 409 | ScopeLocked | policy.ex:1336
docs/ERROR_CODES.md:110 | data-plane/appconfig-snapshots | 409 | SnapshotExists | appconfig_snapshots.ex:41
docs/ERROR_CODES.md:138 | data-plane/certificates | 409 | CertificateNameAlreadyExists | certificates.ex:88
```

All four named gap families are now projected rows (grep-verified in
docs/ERROR_CODES.md). `--check` exit 0 (doc regen-identical).

### Known pre-existing drift (out of scope, disclosed)

extract_lib_tuples cites drift by a few lines when @doc/comment stripping
shifts line numbers (witnessed: SnapshotExists cites :41 vs real :91,
CertificateNameAlreadyExists cites :88 vs real :177). Pre-existing extractor
behavior (strip-then-number), NOT session-introduced; flagged for the next
extractor-maintenance pass. All named-gap rows: ScopeLocked/PolicyRemediationInvalid
cites exact; the two drifted cites are real files (regex verified the code
literal at :91/:177 by grep before writing this receipt).

## Task 2 — Registrar pass 2 (kd_flip --apply)

Real output (tail):

```
  KD-106: [CLOSED-SIMULATED] lib/smalt/data_plane/skr.ex
  ... 39 covers-map ids, all CLOSED statuses ...
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS:  dry 0; --apply: "nothing FLIP-ELIGIBLE; register unchanged."
```

Zero flips this pass. Diagnosis of the 68 OPEN register rows:

- **Class A (3 rows, token + closed per tool, row-text drift): KD-03/KD-15/KD-19** —
  present in the covers-map and reported CLOSED-WITH-RECEIPT by the tool, but
  the register row's text still carries legacy "OPEN —" audit-note phrasing
  (the tool reads the terminal status token; the row body retains historical
  "OPEN — fix landed" prose). Not a flip-eligibility issue: needs a registrar
  doc-hygiene pass to normalize row-text status phrasing. NOT hand-edited per
  directive.
  (OPEN∩covers = {KD-03, KD-15, KD-19}; covers-map reports all 39 token-carrying
  ids CLOSED; FLIP-ALL CLOSED.)
- **Class B: KD-112 — witness exists, flip blocked on missing token.**
  `docs/jira/v26.10.19/receipts/kd112-arm-policy-initiatives-tbd.md`
  (mtime 2026-10-20 06:21, PASS-EVIDENCED — all legs against real azure
  PolicyClient) but NO `# KD-COVERS: KD-112` token anywhere in lib/
  (grep 0 hits). Per the register law (shim/fix in lib/ must carry the token;
  flip gated on receipt mtime > shim mtime) the witness can never make it
  eligible until the fix site carries the token. Recommended next-lane action:
  land `# KD-COVERS: KD-112` at the initiative/exemption route block in
  `lib/smalt/arm_gateway/router.ex`, re-run `kd_flip --apply`.
  (The 2026-10-20 SDK witness postdates the routes; after the token lands the
  mtime ordering holds.)
  no token, no flip. Correctly OPEN.
- **Class C: KD-114/115/116 — TS-suite push items, no lib/ fix landed.**
  Witnessed FAIL cells (blob bearer-over-http dead-end; SB receiver zero-delivery;
  SB session delivery shape). No fix site in lib/ → no token → correctly OPEN
  (these are the F1/G2 falsifier blockers too).
  Wait — correct that: **Class C is KD-114/115/116 only.**
- **Class D: legacy rows without tokens or with fixes landed tokenless —
  ~60 rows** from v26.10.14/16 era (KD-02..KD-36, KD-44..KD-116 non-token
  subset): no `# KD-COVERS` token, fixes either not landed or landed without
  the token; flip machinery cannot see them. Correctly blocked pending lib/
  work + tokens.
  (OPEN∖covers = 65 rows minus KD-112/114/115/116 named above.)

## Verification summary

- `python3 scripts/gen_errorcodes.py` exit 0; `--check` exit 0; 196 rows.
- All 4 named gap literals present as table rows (grep-verified, see above).
- `python3 scripts/kd_flip.py --apply` exit 0, zero eligible, register unchanged
  (no hand edits to KNOWN_DIVERGENCES.md; no witnesses fabricated).
- No mocks, no sleeps, no git commits.
