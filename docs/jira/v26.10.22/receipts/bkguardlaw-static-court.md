# BK-GUARDLAW — Static-Law Court for the Workspace Engine Laws

**Standing: ALIVE** (court green, non-vacuity witnessed) · **Context: solo**

Lane: BK-GUARDLAW · Milestone v26.10.22

## What

`workspace/scripts/law-static-court.mjs` — a plain-node static-law court that
greps the engine sources for each admission law's mechanically-checkable shape
and fails typed naming the law (LAW-n) when a shape is absent. Seven law
entries / 19 shape checks over five files:

| Law | File | Shapes |
|---|---|---|
| LAW-1 SHACL-FAILCLOSED | `workspace/workers/law-reticle.worker.ts` | typed `SHACL_VERDICT_ABSENT` refusal; `"conforms" in r.value` presence gate; `typeof conforms !== "boolean"` gate; `conforms === false` refuses |
| LAW-2 GUARD-TIMEOUT | `workspace/lib/engine/guard.ts` | `DEFAULT_CALL_TIMEOUT_MS = 10_000`; ctor default consumes it; typed `GUARD_TIMEOUT` fault detail |
| LAW-3 CLIENTID-PERSIST | `workspace/lib/engine/useSovereignTerminal.ts` | `ensureClientId` imported + awaited on the page boot path |
| LAW-3b CLIENTID-PERSIST-TURNSTILE | `workspace/lib/engine/journal-sync.ts` | `ensureClientId` export; `clientIdQueue.run` FIFO turnstile; single readwrite tx mint |
| LAW-4 RESERVED-PAD | `lib/smalt/sync/frame.ex` | server typed `BAD_RESERVED` refusal; `pad != <<0::32>>` compare |
| LAW-4b RESERVED-PAD-CODEC | `workspace/lib/engine/codec.ts` | `HEADER_LEN = 41`; reserved pad stays zero pin |
| LAW-5 DISPOSE-FAILCLOSED | `workspace/lib/engine/guard.ts` | in-flight admissions resolve typed fault on dispose; timers cleared |

Exit contract: 0 all laws pass / 1 any law fails (typed, names law + missing
shape). Root override `LAW_STATIC_COURT_ROOT=<dir>` reads sources under a
scratch copy (used for the non-vacuity proof below; production run uses the
repo root).

## Honest typing

**This is a tripwire layer over the runtime courts, not a replacement.** A
static shape check proves the text is present, not that the behavior is
correct — guard-court / exp1c-journal-court / codec-court / receipt-court
remain the register of truth for the laws' semantics. What this court closes
is the regression channel a runtime court cannot see between runs: a refactor
that silently deletes a law's load-bearing line leaves the runtime courts
green until the next execution against the mutated source; this court fails
typed at the next static run, naming the law and the missing shape.

## Embedded court output (real run, exit 0)

```
[PASS] LAW-1 SHACL-FAILCLOSED  (workspace/workers/law-reticle.worker.ts)
       [ok] typed-absent-refusal
       [ok] conforms-presence-gate
       [ok] conforms-boolean-gate
       [ok] false-refuses
[PASS] LAW-2 GUARD-TIMEOUT  (workspace/lib/engine/guard.ts)
       [ok] timeout-constant
       [ok] ctor-default-consumes
       [ok] typed-timeout-fault
[PASS] LAW-3 CLIENTID-PERSIST  (workspace/lib/engine/useSovereignTerminal.ts)
       [ok] import
       [ok] call
[PASS] LAW-3b CLIENTID-PERSIST-TURNSTILE  (workspace/lib/engine/journal-sync.ts)
       [ok] ensureClientId-export
       [ok] fifo-turnstile
       [ok] single-tx-mint
[PASS] LAW-4 RESERVED-PAD  (lib/smalt/sync/frame.ex)
       [ok] server-typed-refusal
       [ok] server-pad-compare
[PASS] LAW-4b RESERVED-PAD-CODEC  (workspace/lib/engine/codec.ts)
       [ok] header-contract
       [ok] pad-stays-zero
[PASS] LAW-5 DISPOSE-FAILCLOSED  (workspace/lib/engine/guard.ts)
       [ok] in-flight-resolve
       [ok] timers-cleared

static-law court: 7 laws PASS (tripwire over runtime courts)
EXIT=0
```

## Non-vacuity (shim-court shape, on a scratch copy — never the canonical tree)

BASELINE scratch copy -> court exit 0. SHIM (marked `# SHIM-COURT`):
`DEFAULT_CALL_TIMEOUT_MS = 10_000` mutated to `5_000` in the scratch
`guard.ts` — the law's load-bearing constant removed. AFTER:

```
[FAIL] LAW-2 GUARD-TIMEOUT  (workspace/lib/engine/guard.ts)
       [MISS] timeout-constant
       [ok] ctor-default-consumes
       [ok] typed-timeout-fault
...
[FAIL] LAW-2 GUARD-TIMEOUT: missing shape(s) in workspace/lib/engine/guard.ts -> timeout-constant (/DEFAULT_CALL_TIMEOUT_MS = 10_000/m)
EXIT=1
```

RESTORE: scratch guard.ts replaced from canonical; `diff -q` byte-exact
("RESTORE byte-exact"); court back to EXIT=0; scratch dir deleted. The court
flips on the removal — it is not vacuous.

## Verification ladder

- narrow: node syntax (court runs, typed per-law manifest) — exit 0 on the
  canonical tree, exit 1 typed on the shimmed scratch copy.
- Pre-existing state: no engine/lib sources touched by this lane; the court
  is additive (one script + this receipt).
