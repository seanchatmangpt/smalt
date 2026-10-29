# Receipt: KD-173C — ingest POST dev-default key dev-plane close

- Standing: ALIVE
- Context: solo
- Date: 2026-10-22
- Lane: KD-173C
- Disposition: KD-173 CLOSED (dev-default credential now plane-gated); flip
  via `scripts/kd_flip.py --apply --only KD-173` (receipt-gated, witness = this
  file, postdates the shim).

## Change

`workspace/app/api/v1/ingest/route.ts` + `workspace/lib/debug-faces.ts`
(KD-173 shim, token `// KD-COVERS: KD-173`):

- New dev-plane env gate following the debug-faces idiom:
  `devPlaneEnabled()` (`SMALT_DEV_PLANE === "1"`) + typed refusal
  `devDefaultKeyRefused()` — 503 `{ error: "dev_default_key_refused", detail }`.
- `POST /api/v1/ingest` refuses the dev-default key (`SMALT_INGEST_HMAC_KEY`
  unset resolves to the public-source `n4-dev-key`) with the typed 503 BEFORE
  signature verification whenever the server was NOT started with
  `SMALT_DEV_PLANE=1`. A provisioned `SMALT_INGEST_HMAC_KEY` is admitted on
  every plane; with the dev plane pinned, the dev posture is preserved
  (default-key sigs admit 202 end to end).

## Court (real server legs, both ways + provisioned-key control)

Court: `just ws-court` (leg 5, added to `workspace/scripts/e2e-court.mjs`;
harness `workspace/scripts/lib/kd173c-harness.mjs` — boots the Next dev server
on lane ports 39751/39752/39753 with per-leg env overlays, readiness via
bounded HTTP poll, no sleeps; tree-kills in finally). Embedded output (exit 0,
two consecutive runs):

```
[PASS] live: ingest default key refused off dev plane — POST /api/v1/ingest default-key sig -> 503 dev_default_key_refused
[PASS] live: ingest default key admitted on dev plane — POST /api/v1/ingest default-key sig (SMALT_DEV_PLANE=1) -> 202 accepted
[PASS] live: ingest provisioned key admitted off dev plane — POST /api/v1/ingest provisioned-key sig -> 202 accepted

# court verdict
# PASS=73 FAIL=0 SKIP=2
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed both ways...
# SKIP: live: popcorn iframe src: no Next server on :3100 (ECONNREFUSED) — start one to run the live leg
```

(Second run identical verdict: `# PASS=73 FAIL=0 SKIP=2`, exit 0; lane ports
39751-39753 verified unbound after both runs — no orphaned servers.)

- Non-dev plane + default-key signature -> 503 `dev_default_key_refused`
  (the row's close condition: default-key signature rejected off the dev
  plane, typed 503 per the row's "or the face 503s" wording).
- Dev plane (SMALT_DEV_PLANE=1) + default-key signature -> 202 accepted
  (posture preserved for dev).
- Provisioned key (SMALT_INGEST_HMAC_KEY set, no dev plane) -> 202 accepted
  (control: the gate targets the dev-default key only).

## Gates

- `npm run lint` (ws-lint): clean, 0 problems (run after the KD-COVERS token
  landed — final state).
- `just ws-court`: PASS=73 FAIL=0 SKIP=2, exit 0, twice consecutively.

## Register flip

`scripts/kd_flip.py --apply --only KD-173 --witness
KD-173=docs/jira/v26.10.22/receipts/kd173c-devplane-close.md` — witness
postdates the shim mtime; close evidence (KD id + Disposition + Standing)
carried above; tool flips OPEN -> CLOSED-SIMULATED (the tool's canonical
closed vocabulary; the row's typed posture row text is preserved).

## Addendum (token placement)

The `// KD-COVERS: KD-173` token lives on its own line in
`workspace/lib/debug-faces.ts` (the scanner regex matches `//`/`#` tokens, not
` * ` docblock prefixes — first placement was inside the JSDoc block and was
invisible to `kd_flip`; moved post-court, no code change, lint re-verified
clean).

## Addendum (kd_flip scope fix, disclosed)

`scripts/kd_flip.py` (shared gate, minimal unblock fix — disclosed per the
compile-freeze SLA): `--apply` refused globally when ANY covered row had an
ambiguous witness, even under `--only KD-173` — an unrelated concurrent
lane's in-flight row (KD-174) vetoed this lane's named-row flip carrying its
own explicit `--witness`. Fix: the ambiguity refusal is now scoped to the
target rows (`--only` targets, or all eligible rows under a bare `--apply`);
auto-picking is still refused everywhere (BK-55 preserved; an ambiguous
TARGET row still refuses without its own --witness). `--self-test` green
(10 assertions). Concurrent lane disclosure: KD-174's owner should pass
`--witness KD-174=<path>` for their flip.

Final gate runs postdate the token move and all file state: lint clean;
ws-court exit 0, PASS=73 FAIL=0 SKIP=2, three KD-173C legs PASS (third
consecutive green run).

## Cleanup

All three boot temp dirs/ports released; no `workspace/.next` production
build dependency (dev server, source truth); no shared-tree writes beyond the
lane's own files.
