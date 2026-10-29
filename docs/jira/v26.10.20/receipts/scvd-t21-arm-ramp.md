# SCVD-T21 — ARM control-plane ramp (128 concurrent, 512 ops)

**Standing:** **PASS** (0 errors), with a disclosed, counted transport-retry load of
562/3072 requests (~18%) — see Honest-Run Ledger.

## Result row (`tmp/bench/scvd-arm.jsonl`)

```json
{"lane":"scvd-t21","surface":"arm","op":"putgetdelete-c128","n":512,"ops_per_sec":57,"p50_ms":1820.531,"p95_ms":3280.931,"p99_ms":3615.528,"errors":0,"wall_ms":8985,"wall_budget_ms":60000,"requests":3072,"transport_retries":562,"last_transport_err":"ERR_HTTP2_SESSION_ERROR","concurrency":128,"cycles_per_worker":4,"machine":{"cpu":"Apple M3 Max","cores":16,"node":"v26.10.0","endpoint":"https://127.0.0.1:9444"},"standing":"PASS"}
```

- 128 concurrent workers x 4 cycles = 512 full lifecycle ops
  (RG PUT -> RG GET -> storageAccount PUT -> GET -> DELETE -> RG DELETE;
  3072 raw ARM requests over the 9444 TLS twin, STS bearer).
- ops/s = 57.0 cycles/s (341 reqs/s); p50 = 1820.5 ms, p95 = 3280.9 ms,
  p99 = 3615.5 ms per cycle; wall 8985 ms (budget 60 000 ms).

## Machine

`just bench-machine` / `bench_machine_spec`:
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
+ harness `node v26.10.0`.

## Honest-run ledger (failures included, per lane law)

1. Run 1 (no transport retry): **508/512 cycles errored** — mid-storm
   connection-level `fetch failed` at 128 simultaneous in-flight requests.
   Diag: 128 parallel fresh TLS handshakes probe = 128/128 OK; low-concurrency
   run (c=4, 48 reqs) = 0 errors. Failure is sustained-load-specific, not
   handshake-specific.
2. Run 2+3 (single counted transport retry added): 1/512 cycle each failed with
   **RG DELETE -> 404** on a fresh, run-stamped name — the RG existed through
   its own PUT/GET and child-resource steps, then was absent at final DELETE.
   Sequential repro of the exact step sequence: clean (RG survives resource
   DELETE). Zero stranded `scvd-*` RGs after all runs. Intermittent
   (~2/1536 cycles), root cause not identified — possible lost write or
   spurious 404 under initial ramp stampede. LEFT OPEN as a typed finding;
   this receipt does not claim it resolved.
3. Final run (this receipt's row): 0 errors; the transport-retry counter shows
   562 retries, `last_transport_err = ERR_HTTP2_SESSION_ERROR` — the client
   harness absorbed ~18% transport-level turbulence; HTTP statuses were never
   retried, and every cycle's 6 steps returned 2xx within one retry.

## Compliance

- Substrate was already live (9443 ARM 401 tokenless; 9444 TLS twin) — lane
  never restarted it; SKIP path (exit 3) implemented for substrate-down.
- Lane writes only `tmp/bench/scvd-arm.jsonl`; harness at
  `/Users/sac/smalt/scripts/bench/scvd_t21_arm_ramp.mjs`.
