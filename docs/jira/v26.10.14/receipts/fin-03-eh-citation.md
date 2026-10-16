# fin-03: Event Hubs wire-lane row citation reword (WIRE_PARITY.md)

Date: 2026-10-15. Repo: /Users/sac/smalt. No commits.

## Before (docs/WIRE_PARITY.md:149, tail of row)

> Pinned on the real wire by the `@azure/event-hubs` SDK smoke
> (getProperties / sendBatch / subscribe). | ALIVE |

## After

> Wire-tier claim witnessed at the byte level by the `@azure/event-hubs` SDK
> probe receipt (`sdk-results/ts-event-hubs.md`: real transfer frames with
> `x-opt-sequence-number` annotations over the 5673 lane); the SDK smoke is
> not a currently-green pin — it exits 1 on the mgmt-ops class, see
> KD-18/KD-19/KD-20 in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.
> | ALIVE (wire tier) |

Standing changed ALIVE -> ALIVE (wire tier); the SDK-tier pin is replaced by
the KD cross-refs per the fin-03 work order.

## Verification

- grep over docs/WIRE_PARITY.md for `eventhubs.test.cjs` / `eh-run` /
  `event-hubs`: only rows 149 (edited) and 150 cite the smoke. No other row
  pins a wire/module claim on the smoke as green.
- Finding (not edited, out of lane scope): row 150 ("Event Hubs SDK smoke")
  itself still reads `| ALIVE |` while `sdk-results/ts-event-hubs.md` records
  smoke 0/4, exit 1 (getProperties 501, batch-send smoke-code defect,
  subscribe bootstrap 501). That row is stale on its own tier and needs its
  own DoD pass.
- The doc-truth flag at WIRE_PARITY.md:252-258 ("cites the SDK smoke as its
  pin ... stale until KD-18/19/20 close") now describes the pre-edit state;
  left untouched per minimal-edit scope.

## Replay

`grep -n "eventhubs.test.cjs\|eh-run" docs/WIRE_PARITY.md` and
`sed -n '149p' docs/WIRE_PARITY.md`.
