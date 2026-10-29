# w5k — certificates create-LRO pending face (wf4 fix)

**Standing:** ALIVE
Context: solo
Date: 2026-10-20
Lane: w5k (MIX_BUILD_ROOT=_build-lane-w5k), repo /Users/sac/smalt
Subject:
- `lib/smalt/data_plane/certificates.ex` (owned) — create plants the
  CertificateOperation record `{:pending, name}` atomically after the
  winning `:ets.insert_new/2`; `get_pending/1` answers the operation with
  the synchronous mint completing on first observation
  (`status` `in-progress` -> `completed`, persisted flipped); unknown or
  deleted pending -> typed `404 PendingCertificateNotFound`; soft delete
  drops the pending row.
- `lib/smalt/egress_router.ex` (route patch line, seam disclosed) —
  `get "/certificates/:name/pending"` (3-segment route, unshadowed by the
  2-segment `get "/certificates/:name"`).
- `test/internal/certificates_pending_test.exs` (new) — module-level
  witness incl. a bounded CertificateClient-shaped poller leg (wf4 hang
  falsifier) and typed-404 legs.
- `test/internal/internal_tier_census_test.exs` — census registration:
  owned-file + observable-allowlist entries for the new test, plus the
  in-flight `cosmos_analytical_ttl_test.exs` entries (other lane's file,
  registered under the compile-freeze disclosure below).

## Fixes landed

wf4 finding: the SDK poller hangs on a missing pending face (KD-104 live
witness step 2: `GET .../pending` answered `400 MissingXMsVersion` as a
blob splat fallthrough). The create LRO now has an operation record that
exists and completes, so the poller terminates on `status: "completed"`.

## Compile-freeze disclosures (SLA unblock fixes to other lanes' files)

1. `lib/smalt/messaging/event_grid.ex` — duplicated 3-line
   `put_topic/dispatch` block (SyntaxError: unexpected `end` at :688);
   removed the duplicate copy. Compile-blocking on a fresh build root.
2. `lib/smalt/health.ex` — duplicated unreachable `t0 ->` clause after the
   `_disabled ->` clause in `scheduler_capacity/0`
   (warning: clause cannot match); removed the duplicate clause.
3. `test/internal/internal_tier_census_test.exs` — registered the in-flight
   `cosmos_analytical_ttl_test.exs` (file + its module refs) in the
   population fence / observables allowlist so the shared census reflects
   the on-disk population. No test logic touched.

## Verbatim command output

```
$ MIX_BUILD_ROOT=_build-lane-w5k mix compile --warnings-as-errors
Compiling 7 files (.ex)
Generated smalt app

$ MIX_BUILD_ROOT=_build-lane-w5k mix test test/internal
Finished in 2.0 seconds (0.1s async, 1.9s sync)
48 tests, 0 failures

$ MIX_BUILD_ROOT=_build-lane-w5k mix test test/internal/certificates_pending_test.exs test/internal/certificates_kd104_witness_test.exs
Finished in 0.07 seconds (0.00s async, 0.07s sync)
2 tests, 0 failures
```

## Live-wire witness — b12 enforce, TLS twin 9444 + plain 8443

Substrate restarted (`just substrate-down` + `just substrate-up`, new pid
91251) so the beam serves the landed routes; auth `:enforce` (STS bearer,
1311-char JWT). Script `/tmp/w5k_pending_witness.py`.

```
$ SSL_CERT_FILE=.smalt/tls/ca-cert.pem python3 /tmp/w5k_pending_witness.py; echo EXIT=$?
STS token: 1311 chars
CREATE -> 201
PENDING -> 200 status=completed
  op id=https://127.0.0.1:8443/certificates/w5k-pending-1792501993/pending
POLLER leg: terminated after 1 poll(s) on status=completed
UNKNOWN-PENDING -> 404 b'{"error":{"code":"PendingCertificateNotFound","message":"PendingCertificateNotFo'
DUP -> 409 CertificateNameAlreadyExists
PLAIN-GET -> 200
WITNESS_VERDICT=PASS
EXIT=0
```

First run exited 1: the dup-create leg sent `{}` and the create route's
`with_valid_body` answered `400 InvalidBody` (route-level body gate, not a
regression); re-run with a real policy body passed. Script corrected, not
the surface.

## Standing

- Module + wire faces: ALIVE (witness PASS, EXIT=0; internal tier 48/0).
- No KD register flip attempted — flips ride `scripts/kd_flip.py --apply`
  via the registrar, receipt-gated.
