# r231 — KD-94 up-path witness: real @azure/cosmos AAD bearer vs smalt fixed bearer guard

Standing: **ALIVE** (witnessed execution on the exact subjects; 5/5 subtests pass)

- Date: 2026-10-17 ~03:52 PDT
- Subject (consumer): `/Users/sac/cai/legacy-client/playground/test/smalt-case-space.e2e.test.mjs` (two minimal test fixes this session — see "Test fixes" below)
- Subject (substrate): smalt @ main 7275032 + working tree; substrate booted with `SMALT_TLS_CERTFILE=/Users/sac/smalt/.smalt/tls/dev-cert.pem SMALT_TLS_KEYFILE=/Users/sac/smalt/.smalt/tls/dev-key.pem` (`scripts/substrate.sh up 9>&-`)
- Runner (canonical per the test file's own header; the dispatched `ts-resolve-hook.mjs` is resolve-only and chokes on TS parameter properties in `matter-storage-contract.ts` — the test header documents `j13-ts-resolve.mjs`, which carries the TS transpile load hook):

```
cd /Users/sac/cai/legacy-client/playground && \
NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem \
node --import 'data:text/javascript,import {register} from "node:module"; register("file:///Users/sac/cai/legacy-client/playground/test/j13-ts-resolve.mjs")' \
--test test/smalt-case-space.e2e.test.mjs
```

## Environment repair (disclosed, this session)

1. **Dev TLS leaf did not chain to the CA.** `.smalt/tls/dev-cert.pem` was
   self-signed `CN=127.0.0.1` (issuer self); `openssl verify` failed
   (`error 18 ... self-signed certificate`). Reminted via the sanctioned
   `bash scripts/gen_dev_cert.sh` (it detected the broken chain: "leaf ...
   expired/expiring, or does not chain to the CA — reminting"). Post-fix:
   9444 presents `subject=CN=localhost / issuer=CN=smalt-dev-ca`, and
   `openssl verify -CAfile .smalt/tls/ca-cert.pem .smalt/tls/dev-cert.pem` → OK.
   Boot now requires `SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE` pointing at the
   minted pair, or the substrate falls back to a self-signed lane cert.
2. **Colima ssh port-forward squatting smalt ports.** pid 7846
   (`ssh` — colima VM forward, up since 2026-10-16 23:47) held 9443/9444/8443/
   5672/5673; `scripts/port_sweep.sh -y` skipped it (no kill class for ssh).
   Killed pid 7846 directly (colima re-establishes forwards on demand; VM
   workloads unaffected). Recorded here as a port_sweep class gap.

## Test fixes (legacy-client side, minimal, disclosed)

- FLIP B-leg used doc id `legacy-client-pleadings/pleading-001` (contains `/`): the
  real @azure/cosmos SDK rejects it **client-side** (illegal Resource ID
  chars), so the down-substrate flip never reached the wire. Changed to a
  legal id `legacy-client-flip-probe` (transport-down maps to SMALT_UNREACHABLE
  regardless of doc existence).
- B-leg now calls `ensureCaseSpace({db, coll})` first — the container does not
  survive every substrate reboot cycle (lane-keyed DETS), and the test
  previously depended on out-of-band state.

## Result (verbatim, run of 2026-10-17 ~03:52, full log /tmp/kd94-witness-run3.log)

```
A1 PASS: put/get byte-exact, etag=66148472…, bytes=142
  ✔ A1: CaseSpace put -> get round-trip is byte-exact (30.851458ms)
A2 PASS: delete-while-held 412 LEGAL_HOLD_ACTIVE; release 403 HOLD_RELEASE_REFUSED; held doc intact
A2 PASS: unheld doc deleted, post-delete get is 404
  ✔ A2: legal hold refuses delete and release; an unheld doc deletes and 404s after (78.746959ms)
B PASS: caseDocPut/caseDocGet round-trip on smalt Cosmos db=legacy-client-case-space-e2e, etag="55f359b…
  ✔ B: J8 adapter puts/gets the same case doc on smalt Cosmos (28.897125ms)
FLIP PASS: CaseSpace get with smalt down -> MatterStorageError 503 STORAGE_UNAVAILABLE_OR_OUTCOME_UNKNOWN
FLIP PASS: J8 caseDocGet with smalt down -> SmaltSubstrateError SMALT_UNREACHABLE
  ✔ FLIP: stopping smalt mid-test yields typed refusals, not silent fallbacks (5727.392959ms)
✔ smalt case-space e2e (J4 CaseSpace -> blob twin; J8 adapter -> Cosmos) (5927.643084ms)
ℹ tests 5
ℹ pass 5
ℹ fail 0
```

## KD-94 surface (what the B-leg witnesses)

The B-leg is the **real `@azure/cosmos` SDK** riding its own real bearer
policy — the SDK sends `Authorization: type=aad&ver=1.0&sig=<jwt>` natively
(KD-94's exact divergence shape) — over TLS to `https://127.0.0.1:9444` (the
9444 TLS twin), chain-verified against `smalt-dev-ca`. smalt's fixed
`Smalt.Auth.Bearer` (`lib/smalt/auth/bearer.ex`, 2026-10-16 lane-659 fix)
extracted the sig JWT and verified it via the standard HS256 path. PUT
returned a real `_etag` + `_rid`/`_self`; GET round-tripped byte-exact
(system fields excluded). Wire receipts: 32 `dbs/legacy-client-case-space-e2e`
request lines in `/tmp/smalt-substrate-state/substrate.log` for the window.

Non-vacuity: the FLIP subtest stopped the substrate mid-run and both legs
produced typed refusals (MatterStorageError 503 STORAGE_UNAVAILABLE_OR_OUTCOME_UNKNOWN;
SmaltSubstrateError SMALT_UNREACHABLE) — never a silent fallback. The FLIP
leaves the substrate DOWN by design; confirmed `[STATUS] substrate DOWN` after.

Falsifier for the witness: reproduce with smalt's bearer fix reverted — the
B-leg must then fail with a typed auth error; a PASS under the reverted guard
would refute this receipt.
