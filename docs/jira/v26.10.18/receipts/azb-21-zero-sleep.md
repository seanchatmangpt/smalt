# AZB-21 — Zero-sleep gate (lib + test + burn scripts)

Standing: ALIVE (gate exit 0 on tree; non-vacuity witnessed, 4 legs)
Context: gates (just sleep-gate + just shim-court sleep_gate, 4 legs); no mix test invocation

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-21 (lane gates,
exclusive file `justfile.d/29-sleep.just`; gate script
`scripts/sleep_gate.py`). Deps: none.

## Identity

- Subject: sleep gate v2 (AZB-21 scope extensions) + typed classification
  of the last 37 test-side sites + shim court v2.
- Tree: /Users/sac/smalt @ main (no git ops per lane contract).

## What landed

1. `scripts/sleep_gate.py` (AZB-21 scope):
   - `docker/burn/*.sh` in scope: literal `sleep [0-9]` REFUSED, no
     annotation escape (burn scripts pace via their own loops).
   - `:timer.sleep` treated identically to `Process.sleep`.
   - Same-line `after <integer> ->` delay receives flagged (zero present
     in tree today; the flag is the falsifier fence).
   - String-literal matches are fence fixtures (e.g. the WasmEngine
     no-sleep assertion quoting `Process.sleep(`) — exempted, classified
     {fixture-of-gate} per the ticket's baseline taxonomy.
   - Test-side annotation vocabulary: `TIME-ADVANCE | POLL-STEP`.
   - Allowlist moved into the typed classification file
     `scripts/sleep_gate_classes.json` (files + functions, each entry with
     a reason; fail-closed if missing/unreadable). New entries:
     `await_gone` (test_helper.exs), `do_quiescent_read`
     (test/corpus/helper.exs).
   - Violation lines now name the offending source text.
2. Classification of the last 37 test-side violations (17 files): 19
   inline `# SLEEP-CLASS:` annotations (bounded-poll sites POLL-STEP; real
   time windows TIME-ADVANCE — LRO delay/retry-after/retention windows,
   dets sync tick, monitor-DOWN propagation, async disposition-settle
   propagation, NIF teardown settle, kill-timing jitter, writer pacing);
   2 string-literal fence fixtures (exempted by the gate, not annotated);
   16 already under audited-poll function/file allowlist names now carried
   by the typed classification file. All 17 files re-parse cleanly
   (`Code.string_to_quoted!` receipt below).
3. `scripts/shim_court/sleep_gate_court.sh`: 4 legs — test, lib,
   burn-script, and the ticket's exact anti-vacuity (dual injection, gate
   must NAME both the `Process.sleep(10)` test site and the burn-script
   `sleep 1`). All with_shim protocol: BASELINE sha256 -> BEFORE -> SHIM
   (SHIM-COURT marker) -> AFTER -> RESTORE byte-exact.
4. `docs/NO_SLEEP_DOCTRINE.md`: AZB-21 extension section appended.

## Census delta (ticket baseline 21f58b0: 100 raw hits)

- At ticket open (pre-AZB-21, post W1-W18): gate red with 37 violations
  across 298 scanned files (16 of those were string-literal fence fixtures
  and audited-poll allowlist holders — the red was real but the taxonomy
  was unclassified). Receipt of that state: this session's first gate run,
  quoted below.
- After: `just sleep-gate` exit 0, 306 files, 0 unclassified sleep
  primitives.

## Accept (real output)

```
$ just sleep-gate
[SLEEP-GATE] PASS — 306 files, 0 unclassified sleep primitives
$ echo $?
0
```

count = 0 unclassified. ACCEPT.

## Falsifier / Anti-vacuity (real output)

Falsifier = "a delay primitive present and not flagged" — proven non-vacuous
per leg by the shim court (`just shim-court sleep_gate`, exit 0; each leg
flips BEFORE clean-PASS -> AFTER inject-REFUSE with byte-exact restore):

```
$ just shim-court sleep_gate 2>&1 | grep -E "PASS|RESTORE"
[self-check] sha256 restore-detection verified
... 4 x [PASS] sleep_gate_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib + burn + dual-naming), restore byte-exact
```

Ticket anti-vacuity exact form (leg 4): seed `Process.sleep(10)` in a test
and `sleep 1` in a burn script -> gate exit 1 naming both (court leg 4
asserts the verdict names the test file, the burn script,
`Process.sleep(10)`, and `sleep 1`):

```
$ printf 'Process.sleep(10)\n' > test/.azb21_probe.exs
$ printf '#!/usr/bin/env bash\nsleep 1\n' > docker/burn/.azb21_probe.sh
$ python3 scripts/sleep_gate.py test/.azb21_probe.exs docker/burn/.azb21_probe.sh; echo $?
[SLEEP-GATE] 2 violation(s) across 2 files — REFUSED
  [FAIL] test/.azb21_probe.exs:1 unclassified test sleep primitive in <module body> (audited-poll allowlist or # SLEEP-CLASS: <TIME-ADVANCE|POLL-STEP> required): `Process.sleep(10)`
  [FAIL] docker/burn/.azb21_probe.sh:2 unclassified burn-script `sleep N` (literal shell sleep banned in docker/burn/; see docs/NO_SLEEP_DOCTRINE.md): `sleep 1`
[SLEEP-GATE] lawful forms: bounded poll inside an audited implementation, or # SLEEP-CLASS: TIME-ADVANCE (test) / census class (lib). See docs/NO_SLEEP_DOCTRINE.md
exit=1
```

## Replay

```
just sleep-gate            # Accept: exit 0
just shim-court sleep_gate # Falsifier/anti-vacuity: exit 0
bash scripts/shim_court/sleep_gate_court.sh   # direct equivalent
```

## Parse check on all annotated files (receipt)

```
$ elixir -e 'Enum.each(System.argv(), fn f -> Code.string_to_quoted!(File.read!(f), file: f) end); IO.puts("ALL_PARSE_OK")' <17 annotated test files>
ALL_PARSE_OK
```

## Standing

ALIVE — Accept satisfied on the live tree (exit 0, 0 unclassified),
Falsifier and Anti-vacuity witnessed with real flips (a gate that cannot
flip is FAIL), RESTORE sha256-verified per leg. Burn scripts carried zero
`sleep N` at landing; the gate now fences them. Classification file growth
is a reviewed diff; annotation removal re-fails the site.
