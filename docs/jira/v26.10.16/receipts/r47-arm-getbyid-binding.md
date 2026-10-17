# Receipt — R47 (ARM read-only facade: resources.getById binding)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave W2)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W2 docs lane)

## Subject files

- `workspace/lib/azure/arm-client.ts` — `ArmReadFacade.resources` exposes
  `list | getById`; `getById: client.resources.getById.bind(client.resources)`
  keeps the method bound to the singleton client.

## Verification (2026-10-15, W2 docs lane, unedited output; arm-client.ts compiled standalone with workspace tsc against workspace node_modules, facade built with SMALT_ARM_BASE set, no network calls)

```
resources.getById type=function, name=bound getById
PASS: getById is a function on the read-only facade (binding="bound getById")
exit=0
```
