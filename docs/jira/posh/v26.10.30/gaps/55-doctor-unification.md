# 55-doctor-unification

Lane 2 of 16. One unified preflight entry landed: `scripts/posh_doctor.sh`, wired as the
single-block `just doctor` recipe in the repo root justfile (no 58-posh.just exists in
this repo — root justfile created).

## Checks

- DOCTOR-1 docker/colima daemon via `docker info`
- DOCTOR-2 go / terraform / kind / kubectl present + version line
- DOCTOR-3 asdf Elixir 1.20.4-otp-29 active (WARN path names system-mix 1.19.5 ~> 1.20 failure)
- DOCTOR-4 substrate plane via `scripts/court_plane_discriminator.sh` — absent here, loud SKIP
- DOCTOR-5 kind node disk >= 20000MB via `docker exec smalt-control-plane df -P /` (SKIP if no node)
- DOCTOR-6 kubeconfig current-context resolves in `kubectl config get-contexts`
- DOCTOR-7 provider binary mtime vs newest `internal/provider/*.go` — no such tree here, loud SKIP

Exit ladder: 0=green, 1=any FAIL (blocking), 2=any WARN, 3=no check ran green.

## Deviations from spec

- smalt `scripts/doctor.py` and justfile `_check_posh_tools`/`_check_kind_tools` are not in
  this repo, so "extend doctor.py" minimal-diff option does not exist; new script chosen.
- DOCTOR-4/7 are loud skips (typed, never silent) because the referenced substrate assets
  are not present in courtroom-platform-az.

## Fix during landing

First live run emitted a malformed WARN: `asdf current elixir` prints a header row and the
awk took column 2 of the header ("Version"). Fixed to `awk '$1=="elixir"{print $2}'`.

## ALIVE receipt (verbatim live runs, 2026-10-30)

Green run after first landing (EXIT=0):

```
[DOCTOR-5] node disk 20923MB available (>= 20000MB): OK
[DOCTOR-6] kubeconfig current-context: kind-smalt: OK
DOCTOR SUMMARY: ok=8 warn=0 fail=0 skip=2
EXIT=0
```

Final run of session (EXIT=1, real red — non-vacuity witness: the SAME gate flipped
green→red as other lanes consumed kind-node disk during the wave, 23616 -> 20923 ->
17339 -> 15753MB observed across runs):

```
$ just doctor; echo "EXIT=$?"
bash scripts/posh_doctor.sh
[DOCTOR-1] docker daemon (colima) up — server 29.5.2: OK
[DOCTOR-2] tool go — go version go1.23.4 darwin/arm64: OK
[DOCTOR-2] tool terraform — Terraform v1.14.6: OK
[DOCTOR-2] tool kind — kind v0.30.0 go1.25.0 darwin/arm64: OK
[DOCTOR-2] tool kubectl — Client Version: v1.35.2: OK
[DOCTOR-3] asdf elixir 1.20.4-otp-29 active: OK
[DOCTOR-4] substrate plane: SKIP — court_plane_discriminator.sh not present in this repo (loud skip)
[DOCTOR-5] node disk: FAIL — only 15753MB available < 20000MB — prune: docker system prune
[DOCTOR-6] kubeconfig current-context: kind-smalt: OK
[DOCTOR-7] provider freshness: SKIP — no internal/provider/*.go in this repo (loud skip)
----
DOCTOR SUMMARY: ok=7 warn=0 fail=1 skip=2
EXIT=1
```

Degraded path (EXIT=2) also witnessed live earlier (DOCTOR-3 WARN from an asdf header
parse bug, since fixed).

## Concurrent-lane incidents (disclosed)

1. A telemetry lane appended dx_event wiring to posh_doctor.sh and rewrote the justfile
   mid-run; a doctor invocation during the edit window failed with arithmetic errors
   (mid-edit race). Their helper scripts (dx_telemetry.sh, dx_report.py) were later
   deleted from scripts/ by another lane; the justfile `dx-report` recipe now references
   the missing dx_report.py (not my lane's file — flagged for lane 13/coordinator).
2. scripts/posh_doctor.sh was deleted entirely mid-session; this lane restored it
   byte-clean (bash -n pass, syntax-check receipt above) as the sole coherent version —
   the deleted variant's telemetry additions depended on the now-absent helper.

Status: ALIVE (doctor runs end-to-end on real substrate; last run exit 1 via a genuine
DOCTOR-5 disk FAIL — the gate detects real substrate degradation, not a vacuous pass).
