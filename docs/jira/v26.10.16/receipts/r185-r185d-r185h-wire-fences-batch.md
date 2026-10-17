# Receipt — R185 / R185d / R185h (wire fences + TLS + policy-row wire tier)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 late docs sweep, lane 267)
- **Standing:** PASS (R185, R185h); PASS (R185d) — all re-run on `_build-lane267`
- **Date:** 2026-10-16 (W-late docs lane, batch 1 of 5)

## What landed

- **R185** (repair lane; egress wire fences): the R137 percent-encoded
  reserved-namespace fence over the REAL wire lives in
  `test/wire/egress_wire_test.exs:373` — encoded `/%6beys/` PUT answers
  404 envelope naming the reserved namespace + nothing-stored law; encoded
  `/%64bs/` GET answers flat 400 NotImplemented; plain `/vltkv/...` splat
  stays 201 (whitelist-law flip witness). Marker: `# R137 (repair lane R185)`.
- **R185d** (per-seat TLS cache): `lib/smalt/tls.ex:47` — "the dev cert is
  per-seat state, never a shared file" (`TLS-261014-01`). Covered by
  `test/tls_test.exs`.
- **R185h** (wire tier for the R133 policy-row CAS): `test/wire/egress_wire_test.exs:431`
  — concurrent container metadata PUTs vs legal-hold toggles over REAL TCP
  answer only legitimate verdicts (200 / 409 ContainerLocked, never 500),
  with the serialized 409 gate stamping `x-ms-error-code` (R181 parity).
  Marker: `# R185h (repair lane from DoD D129 — wire tier for the R133 policy-row CAS)`.

## Verification (2026-10-16, lane 267, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane267 mix test test/wire/egress_wire_test.exs --include amqp_wire
15 tests, 0 failures
exit=0
$ MIX_BUILD_ROOT=_build-lane267 mix test test/wire/egress_wire_test.exs --include wire
15 tests, 0 failures
wire_exit=0
$ MIX_BUILD_ROOT=_build-lane267 mix test test/tls_test.exs
20 tests, 0 failures
exit=0
```

The same 15-test wire run covers R185 and R185h (both `@tag :wire` tests in
`test/wire/egress_wire_test.exs`); the suite runs the wire tier green under
either include, exit 0.

## Standing

PASS — suite-grounded, re-verified on `_build-lane267`.
