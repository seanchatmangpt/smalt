# i29 — scratch-py sweep #2 (blob_worm_witness None-guards)

Date: 2026-10-18

Context: solo (single lane, no concurrent writers on this surface)

## Claim swept

Task premise: a stray root-level `blob_worm_witness.py` with Pyright None-typed
`spec_from_file_location` defects. Sweep result: **no such stray file exists**.
`ls /Users/sac/smalt/*.py` → no matches; no `blob_worm_witness.py` anywhere
outside `scripts/shim_court/` (`find -maxdepth 2`). `/tmp/*.py` files are
lane scratch outside repo scope and were left untouched.

## What was fixed

The only copy is the tracked, referenced
`/Users/sac/smalt/scripts/shim_court/blob_worm_witness.py`
(`blob_worm_court.sh:30` WITNESS, `docs/reference/courts.md:44`) — referenced,
so fixed in place rather than moved. `load_gate()` gained the proper
None-guards:

```python
spec = importlib.util.spec_from_file_location("blob_worm_gate", path)
if spec is None or spec.loader is None:
    raise SystemExit(f"[witness] cannot load gate module from {path}")
```

## Verification (real output)

- `pyright scripts/shim_court/blob_worm_witness.py`
  → `0 errors, 0 warnings, 0 informations`
- `python3 scripts/shim_court/blob_worm_witness.py refuse gates/blob_worm_gate.py`
  → `[witness] refuse leg: mutated write against WORM-locked container REFUSED (409/ContainerLocked enforced)`
  → exit=0

## Standing

PASS — premise corrected (no stray file moved, nothing to relocate);
referenced witness hardened, pyright-clean, refuse leg green on the real gate.
