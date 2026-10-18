# Rewrite drafts — JS/Python SDK harnesses (structural teardown + readiness polls)

Repo: /Users/sac/smalt (read-only; drafts only). Basis: file reads + grep on
2026-10-18, current tree. Chicago rule: no wall-clock coordination; poll
observable readiness with deadlines. Fixed `sleep`/`setTimeout` delays that
gate a *transition* (boot, teardown, delivery) are the defect class; a
backoff *inside* a deadline-bounded readiness poll is compliant and is kept.

Draft legend: REPLACE / ADD / KEEP (with rationale).

---

## 1. test/sdk-smoke/run.mjs — post-teardown-fix

### 1a. Structural teardown (primary fix)

**Defect (witnessed, i21c-T3, receipts/i21c-t3-sdk-smoke.md):** teardown is
`process.on("exit")` (lines 105-109, 170). The spawned `mix run --no-halt`
beam child keeps the event loop referenced, so the `exit` handler never
fires, `exitCode` is never consulted, and the court watchdog killed the
harness at 30 min (exit 124) on a fully green 286ms probe set. The current
`process.exit(code === 0 ? 0 : 1)` at line 293 is a band-aid: it forces the
`exit` event, but any early `return` path that sets only `process.exitCode`
(lines 57, 126, 191, 218, 226, 259) still relies on the event loop draining
— and every failure path re-spells `killSubstrate("SIGKILL"); killEnforce();`
by hand (6 copies), so one missed copy leaks a beam.

**Draft:** wrap the whole body of `main()` after the spawns in
`try { … } finally { killSubstrate("SIGTERM"); killEnforce(); }`, dispose the
child handles, and let `main()` be the only place exit codes are decided.

```js
// signal handlers keep only the crash path (they run when the loop is alive);
// the finally block is the teardown of record for all completion paths.
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => { killSubstrate("SIGKILL"); killEnforceRef.fn?.(); process.exit(130); });
}
// DELETE: process.on("exit", …) handlers at lines 109 and 170.

async function main() {
  // … port checks, spawn substrate, spawn enforce …
  try {
    // 3-4 as today (polls, token mint, mode self-check, testRun)
    const code = await new Promise((resolve) => testRun.once("close", resolve));
    process.exitCode = code === 0 ? 0 : 1;
  } finally {
    killSubstrate("SIGTERM");   // escalation to SIGKILL stays inside killSubstrate
    killEnforce();              // killEnforceRef.fn stays for the crash path
  }
}

main().catch((err) => {
  console.error("[sdk-smoke] termination is structural", err);
  process.exitCode = 3;
});
```

Concrete edits:

1. **REPLACE** lines 287-293 (the `testRun` close + comment + hard
   `process.exit`) with: `const code = await close-of(testRun)` → set
   `process.exitCode` → fall through to `finally`. Delete the v26.10.17
   band-aid comment. `process.exit()` is then used only in signal handlers
   (exit 130).
2. **ADD** `try/finally` around main-body section 3→4. `finally` calls
   `await killSubstrate("SIGTERM")` + `killEnforce()`. Remove the 6 inline
   `killSubstrate("SIGKILL"); killEnforce(); process.exitCode = 2;` pairs on
   failure paths — replace each with `process.exitCode = 2; return;` (the
   `finally` does the killing).
3. **KEEP** `detached: true` + process-group kill (`process.kill(-pid)`)
   inside `killSubstrate`/`killEnforce` — group kill is part of the
   structural guarantee, not wall-clock.
4. **KEEP** the 5s escalation inside `killSubstrate` (signal → bounded wait
   on `child.close` → SIGKILL). It is deadline-bounded, not coordination.
5. **ADD** handle disposal so the loop can drain naturally even without
   `process.exit`: in the `finally`, after the kill sequence, call
   `logStream.end()`, `enforceLog.end()`, `child.stdout.destroy()`,
   `child.stderr.destroy()` (and enforce twins). Optional belt-and-suspenders
   `process.exit(process.exitCode || 0)` at the very end of `main()` after
   the `finally` completes — permitted because teardown is now *before* it,
   not inside an `exit` event.
6. **KEEP** signal handlers (crash path only). **DELETE** the two
   `process.on("exit", …)` registrations.

### 1b. Boot poll is already compliant — KEEP

Section 3 (lines 111-135) polls TCP 9443/8443 with a 60s deadline and 500ms
backoff; section 3b (173-195) polls the enforce twin and additionally breaks
on `enforce.exitCode !== null` (child-death detection — good; the anonymous
poll at 114 could adopt it too). No fixed delay gates boot. KEEP as-is;
optional ADD: `if (child.exitCode !== null) break;` in the first poll loop.

### 1c. Optional: single boot helper

Sections 3 and 3b are the same poll with different port sets and env. A
`bootSubstrate({ eval, ports, env })` helper would collapse them and make the
finally-block teardown cover both children uniformly. Second-wave candidate,
not load-bearing.

---

## 2. test/sdk-smoke/census-run.mjs

Already has `try/finally` around `runProbes`-equivalent (lines 139-141:
`process.exitCode = …; await killSubstrate("SIGTERM")` after close) — but it
is **not** a `finally`: if the `spawn("node", …)` throws, or a future edit
adds an early return between poll and spawn, teardown is skipped and the
exit-handler (line 100) must fire — same event-loop dependence as run.mjs
(its beam child references the loop, so `exit` may never run).

**Draft:**

1. **REPLACE** lines 139-141 with `try { const code = await closeOf(testRun); process.exitCode = …; } finally { await killSubstrate("SIGTERM"); }`.
2. **DELETE** the `process.on("exit", …)` at line 100 (keep signal handlers,
   line 97-99). With the finally in place the exit handler is dead code whose
   only remaining role is masking a missing finally.
3. **KEEP** `killSubstrate` escalation design (SIGTERM → 5s bounded wait →
   SIGKILL) and the 500ms/60s boot poll (lines 102-121) — compliant.
4. **ADD** `if (child.exitCode !== null) break;` inside the boot poll loop
   (early-out when the beam dies mid-boot instead of burning 60s).

---

## 3. test/sdk-smoke/eh-run.mjs

Same shape as census-run.mjs. `process.on("exit")` at line 112; teardown at
149-151 (`process.exitCode = …; await killSubstrate("SIGTERM")`) is sequenced,
not guaranteed.

**Draft:** identical to census-run: try/finally around the testRun section,
DELETE line 112 exit handler, KEEP polls (114-134) and killSubstrate
escalation (89-108). ADD child-death early-out (`child.exitCode !== null`)
in the boot poll — eh-run's poll (116-133) lacks it.

---

## 3'. Misc notes

- `run-all.mjs` (not re-read this pass; same family) — apply the same
  try/finally + delete-exit-handler pattern when touched.

---

## 4. test/sdk-python/run.sh (lane PY-5)

### 4a. Teardown

`cleanup()` (lines 48-53) is a `trap cleanup EXIT` — structural in bash
(EXIT trap fires on all paths, unlike node's `exit` event). **KEEP** — but
two defects:

1. `sleep 1` between TERM and KILL is a fixed wall-clock wait. **REPLACE**
   with a bounded liveness poll:
   ```bash
   cleanup() {
     kill -TERM -- -$SUB_PID 2>/dev/null || kill $SUB_PID 2>/dev/null
     for _ in $(seq 1 20); do
       kill -0 $SUB_PID 2>/dev/null || break
       sleep 0.1   # bounded: 20 x 0.1s deadline, not a fixed wait
     done
     kill -KILL -- -$SUB_PID 2>/dev/null
   }
   ```
2. `run.sh` boots the substrate **while holding the primary flock** and the
   PY-5 finding (comment at lines 21-29) says a detached beam inherited fd 9
   and leaked the lock. run.sh spawns via `… >"$LOG" 2>&1 &` without closing
   fd 9: **ADD** `9>&-` on the mix line (same-checkout-fanout addition #4,
   lock fd inheritance law):
   ```bash
   MIX_ENV=test mix run … 9>&- >"$LOG" 2>&1 &
   ```
   With the leak fixed, the fallback lane lock branch (lines 27-33) becomes
   dead-but-harmless; keep it as a tripwire.

### 4b. Readiness poll — KEEP

Lines 56-61 poll nc -z on 3 ports with 60x1s deadline — compliant. Two
nits: 1s granularity is coarse; `nc -z` on a UDP-capable invocation can
false-positive — pin TCP (`nc -z 127.0.0.1 $PORT` is TCP by default on macOS
nc; fine). Optional ADD child-death early-out:
`kill -0 $SUB_PID 2>/dev/null || break` in the loop so a crashed beam fails
in seconds with the log tail, not after 60s.

### 4c. boot_substrate.py — no readiness, no teardown

`boot_substrate.py` is a bare `subprocess.run([mix run --no-halt …])` with no
poll and no teardown — it blocks on the child forever and termination is
Ctrl-C only. **REPLACE** with a spawn + readiness probe + bounded run
wrapper:

```python
import pathlib, subprocess, os, sys, time, socket

def _up(port, deadline_s=60.0):
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        with socket.socket() as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False

proc = subprocess.Popen([...same argv...], cwd=…)
try:
    if not (_up(19443) and _up(18443) and _up(25672) and _up(25673)):
        proc.terminate(); proc.wait(timeout=5); sys.exit(2)  # SUBSTRATE_TIMEOUT
    ...run whatever this script fronts...
finally:
    proc.terminate()
    try: proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait()
```

(If boot_substrate.py is sourced/exec'd intentionally to hand the foreground
process to the caller, keep the exec semantics but add the `_up` gate before
returning control — readiness before handoff, still no fixed sleep.)

---

## 5. test/sdk-full/*.probe.mjs + ts-run.mjs (any waits)

Shared shape (auth/atlas/eventhubs/eventgrid/sentinel/ts-run all ~lines
90-150): `killSubstrate` SIGKILL branch resolves via
`Promise.race([child.once("close"), setTimeout 5000])` and boot polls use
500ms/60s deadline — both compliant (deadline-bounded). Defects:

1. **Exit-handler teardown in every probe.** Each probe registers
   `process.on("exit", …)` (auth.probe.mjs:215-217 etc.) and the
   "guaranteed" path is `try { await runProbes() } finally { await
   killSubstrate("SIGTERM") }` — the probes **already have the finally**
   (auth.probe.mjs:233-237). So the fix is smaller than run.mjs: **DELETE**
   the `process.on("exit", …)` registrations (they are dead code today and
   mask a missing finally tomorrow) and keep the finally as teardown of
   record. Also ADD `logStream.end()` + stream destroy in the finally for
   loop-drain hygiene. ts-run.mjs's watchdog `setTimeout` at line 181 is a
   deadline, not coordination — KEEP.
2. **Fixed 3000ms delay, eventhubs.probe.mjs:492** (nonexistent-consumer-group
   probe): subscribes with `maxWaitTimeInSeconds: 1` then
   `await new Promise(r => setTimeout(r, 3000))` to "give the error channel
   time". This is wall-clock coordination on a negative observation — a
   fixed delay can only prove "nothing happened *yet*". **REPLACE** with a
   deadline-bounded error-channel poll: wire `processError` to push into
   `errs[]`, then
   ```js
   const end = Date.now() + 5_000;
   while (errs.length === 0 && Date.now() < end) await new Promise(r => setTimeout(r, 200));
   out.push(errs.length
     ? `nonexistent-consumer-group: ${errs[0].name}(${errs[0].code}) …`
     : "nonexistent-consumer-group: no processError within 5s (law: negative observation is bounded-time now, not 3s ago)");
   ```
3. **The 20s/300ms delivery polls** (eventhubs.probe.mjs:252-256, 341-344,
   426-429) are already readiness polls with deadlines — **KEEP**. Cosmetic
   only: the redundant `if (received.length >= N) break;` at line 254-255
   (the while condition already tests it) can be dropped.
4. **auth.probe.mjs:208 / atlas.probe.mjs:113 / ts-run.mjs:126**: SIGKILL
   branch's `setTimeout(resolve, 5000)` race arm is a timeout cap, not a
   coordination delay — **KEEP**.

---

## Compliance summary (poll/deadline vs fixed-wait)

| Site | Verdict |
|---|---|
| run.mjs boot/enforce polls | KEEP (deadline-bounded) |
| run.mjs exit-event teardown | REPLACE (try/finally + handle disposal) |
| census-run.mjs sequenced teardown | REPLACE (try/finally), delete exit handler |
| eh-run.mjs sequenced teardown | REPLACE (try/finally), delete exit handler |
| eh-run/census boot polls | KEEP; ADD child-death early-out |
| run.sh EXIT trap | KEEP; replace fixed `sleep 1` with bounded poll |
| run.sh lock fd | ADD `9>&-` (fanout law #4) |
| boot_substrate.py | REPLACE (spawn + `_up` readiness + finally terminate) |
| *.probe.mjs finally teardown | KEEP; delete dead `exit` handlers |
| eventhubs.probe.mjs:492 3s delay | REPLACE (error-channel poll, 5s deadline) |
| 20s/300ms delivery polls | KEEP |
| SIGKILL 5s race arms | KEEP (timeout caps) |

## Invariants the rewrites must preserve

- Exit-code contract: 0 pass / 1 test fail / 2 substrate never up / 3
  harness failure / 130 on signal. Finally-block must not change exit codes.
- `detached: true` + process-group kill: teardown must keep `kill(-pid)`
  first, `child.kill` fallback — do not "simplify" to `child.kill` only.
- Port-free preflight and its "do NOT kill the holder" messaging: unchanged.
- Mode self-check (3d) ordering: must run before the test suite, unchanged.
- run.mjs §2 `--no-start` + `put_env` eval: unchanged (auth-mode pinning).
- Children env (SMALT_SB_SHARED_KEY / connection strings): unchanged.
- The `# KD-COVERS`/receipt conventions are unaffected; this is harness
  code, no GAP/KD flips ride on it.
