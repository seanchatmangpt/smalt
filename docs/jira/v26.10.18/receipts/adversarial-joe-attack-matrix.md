# Adversarial Joe Armstrong Attack Matrix Receipt
Standing: PASS (4/4 attack vectors + 3 gates PASS; output below)

Context: gates (just sleep-gate, isolation_court.py, just burn-ocel — all PASS) + solo(test/azsim/adversarial_joe_test.exs); no suite-context run

- **Date**: 2026-10-18
- **Commit**: `5a73c47`
- **Subject**: `test/azsim/adversarial_joe_test.exs`
- **Standard**: IEEE OCEL 2.0 / Armstrong Thesis 2003 ("Making reliable distributed systems in the presence of software errors")

## Summary

Answers the four uncompromising failure mechanics straight out of Joe Armstrong's 2003 PhD thesis:
1. **Mailbox Overload & Backpressure**: Proved synchronous dispatch backpressures without unbounded process queue ballooning under 100 concurrent async tasks. Mailbox promptly drains back down to nominal.
2. **Poison Pill Crash Storm & Plane Subtree Isolation**: Leaf worker deterministic crashes (`:deterministic_poison_pill_boom`) do not cascade to sibling planes or bring down root supervisors. Blast radius strictly bounded.
3. **Half-Open TCP & Silent Network Partition**: Abrupt client disconnect without FIN/RST or AMQP CLOSE performative is cleanly dropped by the broker without socket leaks or listener lockup.
4. **Native NIF Panic / Corrupted Bytecode Immunity**: Corrupted wasm bytecode returns typed fail-closed errors (`{:error, _}` / `{:exit, _}`) without native segfault or BEAM core dump.

## Gates Status

- `just sleep-gate`: **PASS** (323 files, 0 unclassified sleeps)
- `python3 scripts/isolation_court.py`: **PASS** (162 test module files, 0 offenders)
- `just burn-ocel`: **PASS** (referential integrity 100% OK)
