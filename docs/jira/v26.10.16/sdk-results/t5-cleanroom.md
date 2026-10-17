# T5 — terraform clean-room ladder (sdk-results receipt skeleton)

Standing: **PENDING-EXECUTION** (authored 2026-10-16 by the docs/ladder lane;
validation-lane update 2026-10-16: the "trusted machine" gate is SUPERSEDED —
keychain trust is now an OPTIONAL persistent alternative, not a machine-class
requirement. Zero-touch shim path validated NON-FLIPPING for terraform
(typed FAIL, WRAP_LEDGER "Zero-touch validation lane" section, lane 397);
until a shim that reaches Go's actual verify surface (anchor-enumeration
interpose) lands, T5 external-tier execution remains gated on the one-time
opt-in keychain trust. The validation lane did NOT execute the ladder —
stage table below intentionally left empty; an empty stage table is not a
skip and not a pass.) The validation lane fills this skeleton with real
output; a skeleton is not a receipt. receipt_index will flag this file SUSPECT
until real command output is embedded — that flag is the standard, not an insult.

Subject: T5 tf_cleanroom — full `apply → plan 0 drift → data-plane audit →
destroy → NFR-4 identity` ladder against the smalt terraform provider.

## Ladder semantics

| Stage | Command (contract) | Budget | Pass criterion |
|---|---|---|---|
| 1. apply | clean-room `terraform apply -auto-approve` | < 30 s | exit 0, plan-count resources created > 0, no `-detailed-exitcode` drift signal |
| 2. plan 0 drift | `terraform plan -detailed-exitcode` | < 30 s | exit 0 (no changes), diff empty |
| 3. data-plane audit | data-plane probes against provisioned endpoints (blob/cosmos/kv per family matrix) | n/a (probe suite budget) | all probes PASS; every probe leg names its family |
| 4. destroy | `terraform destroy -auto-approve` | < 30 s | exit 0, plan-count resources destroyed == created |
| 5. NFR-4 identity | post-destroy residue identity check | n/a | no surviving listeners on the T5 port block, no leftover state files; sha256 of state dir empty-or-attested |

Exit contract (whole ladder): 0 pass / 1 stage fail / 3 harness-skip
(trusted-machine prereq absent → loud `[SKIP] <reason>`, never a faked pass;
no rows emitted on skip).

## Stage table (FILL — validation lane; one row per stage, real output only)

| Stage | Start | End | Wall | Exit | Verdict | Output excerpt |
|---|---|---|---|---|---|---|
| 1. apply | — | — | — | — | — | — |
| 2. plan 0 drift | — | — | — | — | — | — |
| 3. data-plane audit | — | — | — | — | — | — |
| 4. destroy | — | — | — | — | — | — |
| 5. NFR-4 identity | — | — | — | — | — | — |

## Embedded output (FILL — real command output, verbatim)

```
(pending execution)
```

## Budget gate summary (FILL)

- apply wall: — (budget < 30 s) —
- destroy wall: — (budget < 30 s) —
- aggregate: —

## Flip condition

Standing flips PENDING-EXECUTION → PASS only when this file carries the
real stage table + verbatim output + budget gates all green, on a trusted
machine, post-cascade. Any stage red or budget blown → the file records the
typed failure (stage, exit, wall) and standing becomes FAIL — never
silently re-skipped.
