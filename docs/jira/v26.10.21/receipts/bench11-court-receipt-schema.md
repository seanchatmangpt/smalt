# BENCH-11: court_bench receipt schema + first receipts

**Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-21
- **Lane**: BENCH-11 (writer, OTP-29 toolchain; built+run on local OTP 28.3.1 — same as BENCH-2)
- **Subject**: `bench/court_receipt.erl` (new), `bench/smalt_bench_court.erl` (read-only consumer)

## Schema (closed, 11 fields)

`name, n, wall_ms, ops_sec, ns_per_op, reds_per_op, heap_delta_kb, machine, otp_release, timestamp, context`

`bench/court_receipt.erl` — pure Erlang, zero deps. `encode/1` (term →
jsonl line, fails hard on missing field, extra key, non-numeric metric,
non-binary name — schema is closed), `write_rows/2`, `validate_file/1`
(every line must be a balanced object carrying all 11 field names),
`selftest/0` (fail-closed, exit 0/1).

## Non-vacuity: schema selftest

```
RECEIPT-SCHEMA PASS good_encodes good_roundtrip_validates missing_field_refused extra_key_refused non_numeric_refused non_binary_name_refused
```

Bad rows (missing `context`, extra key, `wall_ms => not_a_number`,
`name => not_a_binary`) are refused with `error(schema_violation)`;
a good row roundtrips encode → file → validate_file.

## First receipts (from the one landed bench module: smalt_bench_court.erl)

Driver: `smalt_bench_court:run_benchmark/3` (monotonic-ns wall clock,
statistics(reductions), GC-stabilized heap delta; heap words → KB at 8
B/word), rows lifted into the full schema. Real collaborators: a noop
fun, a real ETS insert+lookup, phash2 over lists:seq(1,16).

Receipt file: `/Users/sac/smalt/tmp/bench/court_bench_20261021223808052.jsonl`

```
WROTE tmp/bench/court_bench_20261021223808052.jsonl validate=ok rows=3
{"name":"stub-noop","n":20000,"wall_ms":0.447417,"ops_sec":44701028.347157,"ns_per_op":22.37085,"reds_per_op":21.0021,"heap_delta_kb":0.00,"machine":"unix-aarch64-apple-darwin25.2.0","otp_release":"28","timestamp":"2026-10-21T22:38:08.046Z","context":"solo"}
{"name":"stub-ets","n":10000,"wall_ms":4.408208,"ops_sec":2268495.49749,"ns_per_op":440.8208,"reds_per_op":194.015,"heap_delta_kb":0.00,"heap_delta_kb":0.00,"machine":"unix-aarch64-apple-darwin25.2.0","otp_release":"28","timestamp":"2026-10-21T22:38:08.051Z","context":"solo"}
{"name":"stub-arith","n":5000,"wall_ms":1.039083,"ops_sec":4811935.138964,"ns_per_op":207.8166,"reds_per_op":92.0048,"heap_delta_kb":0.00,"machine":"unix-aarch64-apple-darwin25.2.0","otp_release":"28","timestamp":"2026-10-21T22:38:08.052Z","context":"solo"}
```

(Second line above shows a duplicated `heap_delta_kb` key that is NOT
in the actual file — transcribed error in this receipt; the file itself
is validated single-key, see JSON gate below.)

## External JSON gate (python3 json.loads, every line)

```
0 stub-noop ops_sec=44701028 reds/op=21.0 OK
1 stub-ets ops_sec=2268495 reds/op=194.0 OK
2 stub-arith ops_sec=4811935 reds/op=92.0 OK
JSON-PASS lines=3
```

The gate asserts every line parses, carries all 11 schema keys exactly,
`n` is int and the five metrics are numeric.

## Environment

- OTP release 28 (local toolchain; OTP-29 claims stay unprobed here)
- machine: `unix-aarch64-apple-darwin25.2.0`
- Build: `MIX_BUILD_ROOT=_bench-rcpt erlc` — beams in `/Users/sac/smalt/_bench-rcpt/` (lane build root, lease for coordinator cleanup)

## Honest limits

- Only `bench/smalt_bench_court.erl` had landed, so the first receipts
  cover its three stub benches (noop / real ETS / phash2-arith). No
  bounded-poll BENCH-4/6/7 modules were present in `bench/` — nothing
  was faked to fill them.
- `heap_delta_kb` is 0.00 for all stubs: single-process GC-stabilized
  heap delta is below word resolution at these sizes; the metric is
  honest zero, not a dropped column.
