# V261019-15 — Verification gates: non-duplication R1/R2/R3, portable-target whitelist, sleep-gate TS/PY extension

> **Status at materialization (2026-10-19):** IN FLIGHT —
> `scripts/non_duplication_gate.py`, `scripts/non_duplication_classes.json`,
> `scripts/portable_target_gate.py` on disk (untracked, gates lane); sleep-gate
> TS/PY scopes and shim courts pending. Note: the verification just module may
> be `32-verification.just` if slot 30 is taken by burn — check before creating.

- **Release:** v26.10.19 · **Work order:** V261019-15 · **Plane:** Verification / gates
- **Scope owners:** new `scripts/non_duplication_gate.py`, new `scripts/portable_target_gate.py`, `scripts/sleep_gate.py` + `scripts/sleep_gate_classes.json` (extension), `scripts/shim_court/lib.sh` + new courts, `justfile.d/30-verification.just` (new, wired into the court ladder)
- **Test surface:** `scripts/shim_court/non_duplication_court.sh`, `scripts/shim_court/portable_target_court.sh` (new); `just shim-courts` aggregate
- **Docs surface:** `docs/verification/` (gate reference), `scripts/shim_court/README.md`

## 1. `scripts/non_duplication_gate.py` — R1/R2/R3

**Ground truth.** The repo already enforces single-source laws piecemeal: `BlobService.xml_escape/1` delegating to `BlobStorage.xml_escape/1` (lane-06 "delegate, do not duplicate"), the boot wrappers (WO-14 §3), `naming_sweep.sh` fail-closed pattern, `sleep_gate.py`'s allowlist file + fail-closed-if-missing discipline. This gate generalizes them into one fail-closed scanner.

**Rules (fail-closed, stdlib only, exit 0 = pass / 1 = violations):**
- **R1 — wrapper purity.** A file under `test/sdk-smoke/*.mjs`, `test/sdk-python/*.py`, or `scripts/lib/` that is *declared* a wrapper (boot.mjs / boot.py / lib sources) FAILS if it contains control flow beyond argument passing/env forwarding: no port math, no lock logic, no listener polling, no `spawn` of anything but `substrate-ctl`. Declared-wrapper set lives in a typed JSON allowlist (the `sleep_gate_classes.json` pattern).
- **R2 — delegated-primitive census.** The known shared primitives (`xml_escape/1`, `request_authority/1`, `assertLocalUrl`, boot library fns) must have **exactly one** implementation site: scanner greps for known duplicate-shaped bodies (second `def.*xml_escape`, second `Joken.Signer.create("HS256"...)` literal, second fd-9 spawn site outside `substrate_boot.sh`) and FAILS on a second definition or literal.
- **R3 — receipt-evidence law.** Receipts asserting a gate/command result must contain real output (exit code, test/probe count, or PASS/FAIL token) — this machine-implements the RECEIPTS.md SUSPECT rule (`receipt_index.py` already flags 13 SUSPECT); the gate FAILS any receipt under an active window dir lacking an evidence token, so new output-less receipts cannot land.

**Non-vacuity:** `scripts/shim_court/non_duplication_court.sh` — BEFORE clean tree passes; SHIM injects a duplicate `xml_escape`-shaped body + an output-less receipt; AFTER gate refuses; RESTORE byte-exact.

## 2. `scripts/portable_target_gate.py` — whitelist

**Fix.** The SDK-matrix/bench/census targets that must run identically from any checkout or lane build root are enumerated in a typed whitelist (JSON: `{targets: [{name, path, kind: mjs|py|sh, portable: true/false}]}` — the `sleep_gate_classes.json` pattern again). The gate FAILS any justfile recipe / harness invocation referencing an SDK target **not** in the whitelist (catches the recurring "lane ran a target the matrix doesn't know" drift), and FAILS a whitelisted target whose path doesn't exist on disk (fail-closed, never SKIP). `portable: false` entries are legal but must be cited as REGISTERED in the SDK matrix.

**Non-vacuity:** `portable_target_court.sh` — SHIM adds a phantom target reference to a justfile; AFTER the gate refuses; restore byte-exact.

## 3. sleep_gate TS/PY extension

**Fix.** Extend `scripts/sleep_gate.py` (currently Elixir/`Process.sleep`/`:timer.sleep`/docker-burn shell scopes) with two new scopes:
- **TS** — `test/sdk-smoke/**/*.mjs` and `workspace/lib/**/*.ts`: bare `setTimeout`/`await new Promise(r => setTimeout(r, N))` with integer N as a coordination step FAILS unless (a) inside the audited poll wrapper (`assertEventually`-class helper, added to the classes JSON `functions` allowlist) or (b) annotated `// SLEEP-CLASS: TIME-ADVANCE` (same semantics as the Elixir class). String-literal exemption and `:infinity`-park analogues (`setTimeout` with no delay) carry over.
- **PY** — `test/sdk-python/**/*.py` and boot.py: `time.sleep(N)` with numeric N FAILS unless inside the allowlisted audited-poll function or annotated `# SLEEP-CLASS: TIME-ADVANCE`.
Classes file gains `ts_files`/`py_files` sections (fail-closed if unreadable, per existing docstring contract). Existing Elixir corpus must remain identically green (no reclassification).

**Fence:** corpus gains one lawful and one unlawful TS site and PY site; gate refuses the unlawful, passes the lawful; `just sleep-gate-court` still PASS.

## 4. Shim courts for each gate (per `scripts/shim_court/lib.sh`)

All three courts follow the lib.sh contract verbatim: `set -euo pipefail` → `source lib.sh` → define `apply_shim` before `with_shim` → BEFORE/SHIM/AFTER/RESTORE with typed `[FAIL:PHASE]` lines; SKIP LOUDLY (rc=3) for missing env, never fake a pass. `sleep_gate_court.sh` is extended (or a sibling added) for the TS/PY scopes with the same BEFORE/AFTER flip.

## 5. `justfile.d/30-verification.just` — wiring

**Fix.** New module exposing:
```
verification-gates            # non_duplication + portable_target + sleep (full sweep)
non-duplication-gate          # §1
portable-target-gate          # §2
sleep-gate (existing, re-exported from 29-sleep.just)
verification-gates-court      # the three shim courts + sleep_gate_court, aggregate summary
```
and **wired into the court ladder**: `scripts/court_x2.sh` (and `verify_all.sh`) gains the `verification-gates` step so the R1/R2/R3 + whitelist + sleep scopes are enforced on every court-x2 run, not on demand. Ladder placement: after compile/warnings gate, before `just gap-sync`.

**Fence:** `just verification-gates` exit 0 on the clean tree; `just verification-gates-court` all-PASS; a court-x2 run shows the new step green (receipt output pasted).

## 6. Sequencing

3 (sleep TS/PY — smallest, unblocks its court) → 1 → 2 → 4 (courts as each lands) → 5 (wiring last) → docs (`docs/verification/` reference pages per gate + shim_court README).
