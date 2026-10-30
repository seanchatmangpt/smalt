# 47: Egress 8443 doc notes + discriminator landing

Lane 47 of 16. Executes ONLY the deferred doc arm of
`~/smalt/docs/jira/posh/v26.10.30/gaps/35-egress-mapping-decision.md`.
No cluster recreated, no kind-config edited, no port mapping added.

## Status

ALIVE — doc notes landed (2 files), discriminator script written AND run
this session (DEFER VALID, exit 0), defer gate re-validated from disk.

## What landed

1. `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/11-kind-ops.md` — dated
   `> UPDATE 2026-10-30 per gaps/35` note under G11-2: fix is DEFERRED; staged
   mapping is host **18443 → containerPort 30843**, NOT hostPort 8443 (native
   beam collision); flip trigger cited.
2. `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/17-unmapped-ports.md` —
   dated `> UPDATE 2026-10-30 per gaps/35` note on the GAP11 close condition:
   same content, 18443 staged, 8443 collides, flip trigger cited.
3. `/Users/sac/cai/courtroom-platform-az/scripts/egress_plane_discriminator.sh`
   — executable G35-1/G35-2 discriminator (arm answers 9443; 8443 must NOT
   answer with the kind backend; `docker port ... | grep 30843` flip trigger).
   Exec bit set. Run this session, verbatim:

```
== G35 egress plane discriminator ==
-- G35-1: plane discriminator --
ARM 9443 /health -> HTTP 401 (http; any HTTP answer incl. 401 = plane alive)
host 8443 /health -> no HTTP answer (refused/timeout)
-- G35-2: mapping existence (mechanical defer-flip trigger) --
G35: UNMAPPED (GAP11 stands, deferral valid)
-- verdict --
DEFER VALID: ARM answers on 9443; host 8443 does not answer with a backend;
no 30843 mapping (exit 0)
EXIT=0
```

Note against G35's expectation of HTTPS-200 on 9443: the kind backend's TLS
face is not serving (HTTPS fails handshake even in-pod); plain HTTP answers
401 (smalt auth gate) — the script treats any HTTP answer as plane-alive.

Current live state also differs from G35's snapshot: `lsof -nP -iTCP:8443
-sTCP:LISTEN` is now EMPTY (native beam not holding 8443 at run time).

## Defer gate: no WAVE consumer needs host→8443

Re-ran the grep from disk this session:

- `grep -rn 8443` over `scripts/ .github/ infra/ README.md gaps/` of
  courtroom-platform-az → zero hits outside the discriminator itself.
- smalt-side 8443 references are smalt-internal only:
  `scripts/acceptance_probe.exs:45`, `scripts/deferred_boot_probe.exs:27`,
  `scripts/release.txt:13/21/25/31`. No courtroom-platform-az consumer.

Deferral valid; flip trigger is mechanical (`docker port smalt-control-plane
| grep -q 30843` → script exits 1).

## Exit contract

| exit | meaning |
|---|---|
| 0 | DEFER VALID — ARM plane answers, host 8443 no backend, unmapped |
| 1 | DEFER VOID — mapping exists; apply pre-staged gaps/35 diff (host 18443 → 30843), recreate, re-run |
| 2 | INCONCLUSIVE — ARM plane not answering; no verdict |

## See Also

`~/smalt/docs/jira/posh/v26.10.30/gaps/35-egress-mapping-decision.md` ·
`~/smalt/docs/jira/posh/v26.10.30/gaps/11-kind-ops.md` ·
`~/smalt/docs/jira/posh/v26.10.30/gaps/17-unmapped-ports.md` ·
`gaps/24-cross-repo-skew.md`
