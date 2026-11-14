# smalt-19 hosting runbook for smalt backend behind fnox.io

Standing: PARTIAL

## Problem

fnox.io hosting is authored but not deployed and registration is pending ACTIVE (observed
this session, fnox repo). smalt side has k8s manifests (`/Users/sac/smalt/k8s/smalt-backend.yaml`,
`/Users/sac/smalt/k8s/smalt-backend-default-deny-ingress.gen.yaml`) and
`/Users/sac/smalt/docker/compose.smalt.yml`, but no
doc maps which of them a hosted fnox demo uses or what ports/env the GCP emulator routes
(`/Users/sac/smalt/lib/smalt/gcp/router.ex`) need exposed. `ls /Users/sac/smalt/docs` shows no
hosting or
runbook doc.

## Acceptance

`/Users/sac/smalt/docs/HOSTING.md` exists; `grep -c 'smalt-backend.yaml\|compose.smalt.yml'
/Users/sac/smalt/docs/HOSTING.md`
is >= 2; `kubectl apply --dry-run=client -f /Users/sac/smalt/k8s/smalt-backend.yaml` exits 0 and its
output
is quoted in the doc.

## Falsifier

Doc names a file or port that does not exist in the repo, or states fnox.io is deployed
or ACTIVE without a receipt.

## Owned files

- /Users/sac/smalt/docs/HOSTING.md

## Depends-on

smalt-08 (register entry for the hosting surface).

## Size

M

## References (path : LOC)

- /Users/sac/smalt/k8s/smalt-backend.yaml : 281 lines
- /Users/sac/smalt/k8s/smalt-backend-default-deny-ingress.gen.yaml : 100 lines
- /Users/sac/smalt/docker/compose.smalt.yml : 54 lines
- /Users/sac/smalt/lib/smalt/gcp/router.ex : 56 lines
- /Users/sac/smalt/docs/ : 25217 files, 32344653 lines total
- /Users/sac/smalt/docs/HOSTING.md : NEW (0 lines, to be created; est. LOC: 80; basis: file-to-use
  map, ports/env table, dry-run output quote)

## Result

Standing: PARTIAL (kubectl dry-run observed rc=0; doc authored, not deployed)
Files: /Users/sac/smalt/docs/HOSTING.md (~62 LOC)
Acceptance: `grep -c 'smalt-backend.yaml\|compose.smalt.yml' /Users/sac/smalt/docs/HOSTING.md` and
`kubectl apply --dry-run=client -f /Users/sac/smalt/k8s/smalt-backend.yaml`

## Repair
W10-05: Standing aligned to PARTIAL in ticket and /Users/sac/smalt/docs/HOSTING.md. Rerun: kubectl apply --dry-run=client -f k8s/smalt-backend.yaml
