# 60 — posh-status as the operator's single glance (GAP60)

## Gap

`just posh-status` was a shallow witness: file-existence echoes plus one curl.
It did not answer the operator's actual questions — which plane is serving,
what is running in-cluster, is the provider binary stale, are the gates green,
what did the last court and the last andon say. It also always exited 0, so a
RED estate read as green in scripts.

## Design

`scripts/posh_status.sh` prints seven typed sections; each is
OK/WARN/FAIL/SKIP(reason); overall exit 0 (no FAIL) or 2 (any FAIL):

| Section | Source | Typing |
|---|---|---|
| PLANE | `scripts/court_plane_discriminator.sh` | NATIVE=OK, KIND/SPLIT=WARN (rc 2), NONE/UNKNOWN=FAIL (rc 3) |
| PODS | `kubectl --context kind-smalt -n default get pods -o wide` (head -10) | all Running/Succeeded=OK, else WARN; unreachable=SKIP |
| ENDPOINTS | host `metadata/endpoints` anchor; if kubectl reachable, in-pod `/.well-known/health/ready` via pod IP | 200=OK, else FAIL / WARN |
| PROVIDER | binary exists? mtime vs newest `*.go` in provider dir | FRESH=OK, STALE=WARN, missing=FAIL |
| GATES | fast re-run of `posh_coverage.py`, `compat_pin_check.py`, `posh_invariant_gate.py` (measured 0.03s/0.08s/0.4s — under the 2s budget) | rc 0=OK else FAIL |
| LAST COURT | newest JSON in `docs/jira/posh/v26.10.30/receipts/posh-court/` | standing PASS/CONFORMANT=OK, FAIL=FAIL, else WARN |
| LAST ANDON | tail `posh/var/andon.jsonl` | composite GREEN=OK, RED=FAIL, else WARN |

Report-only: never builds, never applies, never mutates state.

## Landing

- `scripts/posh_status.sh` (new, executable, `bash -n` clean).
- `justfile.d/58-posh.just`: single disclosed edit replacing the shallow
  `posh-status` body with `exec bash scripts/posh_status.sh` (thin wire,
  GAP60); header comment updated to the typed contract.

## Receipt (ALIVE — command + 2x live output, 2026-10-30)

`./scripts/posh_status.sh` run 1 (20:47:49Z) and run 2 (20:47:52Z) — verbatim
(bodies identical between runs; ages advanced by minutes):

    [POSH-STATUS] === /Users/sac/smalt @ 2026-10-30T20:47:49Z ===
    [POSH-STATUS] PLANE      WARN PLANE=KIND (rc 2)
    [POSH-STATUS] PODS      --- kubectl --context kind-smalt -n default get pods -o wide
    NAME                   READY   STATUS      RESTARTS   AGE   IP            NODE            NOMINATED NODE   READINESS GATES
    posh-sidecar-witness   0/2     Completed   0          48m   10.244.2.15   smalt-worker2   <none>           <none>
    smalt-backend-0        2/2     Running     0          64m   10.244.1.11   smalt-worker    <none>           <none>
    [POSH-STATUS] PODS       OK   all pods Running/Completed
    [POSH-STATUS] ENDPOINTS  OK   metadata anchor 200 on host loopback :9443
    [POSH-STATUS] ENDPOINTS  in-pod /.well-known/health/ready 200 (pod 10.244.1.11)
    [POSH-STATUS] PROVIDER   OK   FRESH: binary newer than all *.go in adapters/terraform-provider-smalt
    [POSH-STATUS] GATES      OK   coverage PASS
    [POSH-STATUS] GATES      OK   compat-pin PASS
    [POSH-STATUS] GATES      OK   invariant PASS
    [POSH-STATUS] LAST COURT FAIL docs/jira/posh/v26.10.30/receipts/posh-court/posh-court-green.json: FAIL | exit 1 | 2026-10-30T18:48:15Z
    [POSH-STATUS] LAST ANDON FAIL composite RED (last: preflight fail 2026-10-30T20:36:28Z)
    [POSH-STATUS] === overall: RED (exit 2) ===

Exit code 2 both runs (LAST COURT standing=FAIL from the F3 lane receipt +
andon composite RED from the kind preflight). This is the truthful estate:
green gates and healthy pods under a RED court/andon — exactly the split the
shallow witness (always exit 0) could not express.

Third live witness through the wire: `just posh-status` 20:48:22Z — identical
sections, exit 2 (just reports "recipe failed with exit code 2").

## Standing

PARTIAL_ALIVE — command ALIVE (3 real runs, exit 2, output above). The RED
verdicts it surfaces (court F3 preflight disk-pressure failure, andon RED) are
owned by GAP25/GAP37 remediation, not by this command.
