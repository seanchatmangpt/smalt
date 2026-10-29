# EXPL1R W1 — repair: law-reticle SHACL admission gate fails closed on response-shape drift

**Standing:** **ALIVE (repair lane)** — fail-closed gate landed and courted at the working tree
(HEAD `4cf4df2` + dirty tree; not committed, per dispatch). Context: solo
Date: 2026-10-21 · Repo: /Users/sac/smalt (main) · Lane: EXPL-1 repair (W1)
Closes the top finding of `expl1-workspace-errc.md` (W1); carries the guard-side half of W6
that lives in an owned file.

## Defect (W1)

`workspace/workers/law-reticle.worker.ts` `evaluate()` op-1 admitted unless
`r.value.conforms === false` — a shacl response missing `conforms` (ABI drift between the
pinned graphlaw.wasm and the worker's JSON contract) fell through every check to
`return { status: 0 }`: every payload admitted, no andon, sieve void while all DOM verdict
fields reported healthy. The `loadWasm` import-surface check already fail-closed; only the
admission verdict itself failed open.

## Fix

- **`workspace/workers/law-reticle.worker.ts`** — evaluation logic extracted to an exported
  pure `evaluateSieve(op, payload, call)` (the worker's `evaluate` delegates with the real
  `callGl`), so the admission contract is courtable in plain node without WebAssembly. The
  op-1 leg is fail-closed:
  - `conforms` must be explicitly present AND boolean-typed, else status 1 with
    `SIEVE_RESPONSE_MALFORMED: conforms field absent|non-boolean conforms (<typeof>)`;
  - `results` must be an array per the verdict ABI, else `SIEVE_RESPONSE_MALFORMED: results field absent`;
  - only then does `conforms === false` → `non-conformant: ...` and `conforms === true` admit.
  op-2 (n3) unchanged: `ok !== true` already refused (no shared verdict shape to harden).
- **`workspace/lib/engine/guard.ts`** (W6 guard-side half, cheap same-class): `dispose()`
  no longer clears pending calls silently — in-flight admissions resolve typed
  `{status: 2, detail: "guard disposed with in-flight admission"}` so the caller gets
  GUARD_FAULT instead of a hung promise or a swallowed verdict.

Court: **`workspace/scripts/guard-court.mjs`** (new, plain node, no framework). Compiles the
real worker + guard with the workspace's own tsc and drives the real `evaluateSieve` with a
hand-written gl JSON responder (simple fake at the wasm boundary, which is not instantiable
in plain node; the collaborator under test is the real admission function).

## Court outputs

`node workspace/scripts/guard-court.mjs` — exit 0, 11/11:

```
[PASS] a  well-formed conforms:true admits — {"status":0}
[PASS] b  conforms:false ANDONs (non-conformant) — reason=non-conformant: minCount at urn:s
[PASS] c  response missing conforms -> SIEVE_RESPONSE_MALFORMED ANDON, no admit — reason=SIEVE_RESPONSE_MALFORMED: conforms field absent from shacl verdict
[PASS] c  no status-0 verdict minted for the malformed shape
[PASS] d  string "true" flipped both legs — reason=SIEVE_RESPONSE_MALFORMED: non-boolean conforms (string)
[PASS] e  op-2 n3 ok:true still admits — {"status":0}
[PASS] e2 transport refusal still ANDONs typed
[PASS] f  missing results array -> SIEVE_RESPONSE_MALFORMED ANDON
[PASS] g  andonRule maps SIEVE_RESPONSE_MALFORMED to the selector
[PASS] h  dispose resolves in-flight admission typed GUARD_FAULT
[PASS] h2 dispose also drains the hung INIT call
# guard court verdict: PASS (0 failure(s))
```

Shim non-vacuity (BK-102 precedent): inverted the conforms guard
(`if (!(!("conforms" in r.value) || ...))` marked `/* SHIM-COURT: fail-open */`) →
`guard-court` exit 1 with 3 leg failures (a, b, d flip):

```
[FAIL] a  well-formed conforms:true admits — {"status":1,"reason":"SIEVE_RESPONSE_MALFORMED: non-boolean conforms (boolean)"}
[FAIL] b  conforms:false ANDONs (non-conformant) — reason=...MALFORMED...
[FAIL] d  string "true" conforms -> ... reason=undefined
# guard court verdict: FAIL (3 failure(s))
```

Restore: sha256 `9e9bf678bc2e3cccd013f135ff74591eb4c323b0a846ea2e2c39a12a8cfbc31a`
byte-exact, post-restore court re-run exit 0.
(Shim v1 note: an `if (false) {` mutation red the court via tsc compile error — an
invalid witness; v2 is compile-clean and flips admission legs.)

Sibling gates:
- `just ws-build` — exit 0 (60/60 static pages, tsc clean).
- `just patterns-court` — exit 0, 13 PASS / 3 SKIP (typed, live-server-dependent) / 0 FAIL.
  Browser P1 admit and P2 refusal legs ran against the REAL pinned wasm sieve — confirms the
  stricter gate does not over-refuse the real artifact's verdict shape.
- `node workspace/scripts/dom-contract-court.mjs` — exit 0, PASS.
- `just ws-lint` — exit 1, **pre-existing, not session-introduced**: both errors are in
  `workspace/lib/engine/useAsyncFn.ts` (untracked, another lane's in-flight file, present in
  the pre-task git status snapshot). Owned files contribute warnings only, all pre-existing.

## Diff

```
workspace/workers/law-reticle.worker.ts | evaluateSieve extraction + fail-closed op-1 leg
workspace/lib/engine/guard.ts           | dispose() drains pending typed
workspace/scripts/guard-court.mjs       | new court (11 legs)
docs/jira/v26.10.22/receipts/expl1r-w1-repair.md | this receipt
```

Falsifier status: W1's falsification court (conforms-absent → typed refuse, conforms-present
→ admit) is leg (c)/(a); a court that admits the conforms-absent response is the vacuity
witness — the shim leg proves the court reds on fail-open. Not committed, per dispatch.
