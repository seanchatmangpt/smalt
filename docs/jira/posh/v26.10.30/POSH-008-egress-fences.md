# POSH-008: egress fences — posh talks only to admitted endpoints

## Task
posh enforces an endpoint allowlist (smalt substrate, kind, explicitly-listed real
hosts in opt-in lanes). Default-deny other egress; violations are typed refusals
logged to stderr receipts. Config: posh.yaml allowlist, loaded at boot, fail-closed
on missing file.

## Acceptance
posh attempting an un-admitted host returns REFUSED(egress-allowlist) typed error;
allowlist bypass attempt is witnessed in a court run.

## Falsifier
Allowlist disabled/empty file -> posh must refuse to boot, not open the floodgates.
