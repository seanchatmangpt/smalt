# HAVE-1: state_ledger.py — run_state.jsonl ledger

**Standing: PASS** (9/9 unit tests OK, real-path CLI smoke executed)
Context: solo(python3 -m unittest tmp/have/test_state_ledger.py — 9/9 + CLI smoke; no mix test invocation)

Component: HAVE L1 state ledger. `/Users/sac/smalt/scripts/have/state_ledger.py`.

## Delivered

1. **Atomic append** — `append_entry()`: each line is written to a temp file in
   the same directory and moved into place with `os.replace` (atomic on POSIX);
   crash mid-append leaves the ledger path fully-formed and the tmp file
   removed (tested via injected `os.replace` failure: ledger stays empty, zero
   leftover `.state_ledger-*` files).
2. **RP-01 step-3 sanitizer** — `sanitize_truncated_lines()`: drops the trailing
   partial line (no terminating `\n`) and any trailing lines that fail JSON
   parse, rewrites atomically, returns `(retained, dropped)`. Same logic
   exposed as `state_ledger.py sanitize --path P` CLI printing
   `retained=N dropped=M`.
3. **Heartbeat** — `heartbeat_touch()` / `heartbeat_age()` over
   `tmp/have/have_l1.heartbeat` (atomic write, age in seconds, `None` if never
   touched). CLI: `heartbeat`.
4. **Schema** — `make_entry()` enforces `{ts, kind, subject, detail}` with
   `kind ∈ {heartbeat, dispatch, receipt, alert}`; invalid kinds raise
   `ValueError`.

Paths `tmp/have/run_state.jsonl` + `tmp/have/have_l1.heartbeat`; `tmp/have/`
added to `.gitignore` (line: `tmp/have/`). Zero sleeps.

## Verification (real output)

Unit tests (`python3 -m unittest tmp/have/test_state_ledger.py -v`,
test file `/Users/sac/smalt/tmp/have/test_state_ledger.py`, real files in
per-test mktemp dirs — Chicago style, no mocks except the injected
`os.replace` crash which asserts real on-disk state):

```
Ran 9 tests in 0.067s

OK
```

Cases: round-trip append/read (schema asserted per entry), invalid-kind
refusal, crash-mid-append leaves no partial state, deliberately truncated
last line `{"ts": 3.0, "kind": "rece` sanitized to `(retained=2, dropped=1)`,
trailing garbage JSON line dropped, clean file is a byte-identical no-op,
empty/missing file `(0, 0)`, heartbeat touch/age, CLI sanitize+append round trip.

Real-path CLI smoke:

```
$ python3 scripts/have/state_ledger.py heartbeat
heartbeat age=0.000s
$ python3 scripts/have/state_ledger.py append --kind dispatch --subject have-l1 --detail "component 1 smoke"
appended at offset 0
$ python3 scripts/have/state_ledger.py append --kind receipt --subject have-l1 --detail "ledger round-trip"
appended at offset 99
$ python3 scripts/have/state_ledger.py read        # → 2 entries, both well-formed
$ printf '{"ts": 1.0, "kind": "alert", "sub' >> tmp/have/run_state.jsonl
$ python3 scripts/have/state_ledger.py sanitize
retained=2 dropped=1
$ python3 scripts/have/state_ledger.py read        # → same 2 entries, truncation gone
$ python3 -m py_compile scripts/have/state_ledger.py
COMPILE-OK
```

## Files

- `/Users/sac/smalt/scripts/have/state_ledger.py` (new)
- `/Users/sac/smalt/tmp/have/test_state_ledger.py` (new, gitignored scratch per receipt discipline)
- `/Users/sac/smalt/.gitignore` (append: `tmp/have/`)

No git actions taken. No sleeps anywhere in the module.
