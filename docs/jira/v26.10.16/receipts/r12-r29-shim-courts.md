# Receipt — R12 + R29 (amqp framing court, EH mgmt court)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `scripts/shim_court/amqp_framing_court.sh` — R12 (V5 verify-lane defect
  history; ENVIRONMENT DEPENDENCY documented per the R12 directive, lib/ not
  edited by the court)
- `scripts/shim_court/eh_mgmt_court.sh:55` — R29: landed delivery builds the
  section list into a `sections` list (2026-10-16 marker)

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ bash scripts/shim_court/amqp_framing_court.sh
VERDICT: NON-VACUOUS — unshimmed witness fails with the recorded signature, shimmed witness passes, restore byte-exact.
EXIT=0

$ bash scripts/shim_court/eh_mgmt_court.sh
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] eh_mgmt_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
EXIT=0
```

Note: the eh_mgmt court's SHIM leg prints intermediate FAIL lines for the
wire-delivery probes (that IS the flip — the shim must change the outcome);
the court verdict line is the binding result.
