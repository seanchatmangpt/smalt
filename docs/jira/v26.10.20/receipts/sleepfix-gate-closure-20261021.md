# sleep-gate residual closure — 2026-10-21

- **Subject**: smalt @ /Users/sac/smalt, branch main (dirty shared tree; lane touched only
  annotation lines, zero logic edits, zero gate edits).
- **Command**: `just sleep-gate` → `just sleep-gate-court`
- **Context**: solo

## Per-site disposition (all 5 from the verify-all sweep SKIP)

| Site | Classification | Rationale |
|---|---|---|
| `verification/ts/fix4.probe.cjs:167` | `// SLEEP-CLASS: POLL-STEP` | Event-driven bounded wait on a real observable (`tx.on("sendable")`) with an 8s watchdog timeout — bounded wait on convergence, not a fixed coordination sleep. |
| `verification/ts/fix4-topic.probe.cjs:48` | `// SLEEP-CLASS: POLL-STEP` | Same sendable-watchdog idiom as above. |
| `verification/ts/sb-emulator.probe.cjs:110` | `// SLEEP-CLASS: POLL-STEP` | Step of a bounded poll loop (12 iterations, explicit 3s deadline) polling `peekMessages` for the messageId observable. |
| `verification/ts/sb-emulator.probe.cjs:213` | `// SLEEP-CLASS: POLL-STEP` | Same bounded peek-poll form. |
| `popcorn_demo/lib/popcorn_demo/apex_ratelimit.ex:236` | `# SLEEP-CLASS: SCHEDULING` (was TIME-ADVANCE — not a lawful lib-side class) | Simulated Cosmos client retry backoff in the rate-limit bench: the runtime scheduling the process away for a modeled real-world interval (docstring updated to match). No behavioral change to `gated_op/4`. |

No site was a genuine violation; no `SmaltTest.AssertEventually` rewrite and no structural
sync was warranted. Gate vocabulary untouched — `scripts/sleep_gate.py`,
`scripts/sleep_gate_classes.json`, and `docs/NO_SLEEP_DOCTRINE.md` unmodified.

## Gate outputs

- `just sleep-gate` → `[SLEEP-GATE] PASS — 416 files, 0 unclassified sleep primitives`, exit 0.
- `just sleep-gate-court` → 12/12 shim courts PASS (test, lib, burn sh x2, verification
  TS/PY x4, popcorn lib/sh/mjs); every court: BEFORE old-signature, AFTER new-outcome under
  SHIM-COURT marker, RESTORE sha256 byte-exact. Exit 0. Non-vacuity intact.

## Standing

**Standing:** PASS — sleep-gate residual from the verify-all sweep closed; 0 unclassified sites;
non-vacuity court still fires on injected sleeps.
