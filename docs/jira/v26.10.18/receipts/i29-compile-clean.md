# i29 compile-clean sweep (warnings-as-errors)

- Standing: ALIVE
- Date: 2026-10-18

Context: solo(fresh-compile census in private root _build-ft-cc, no shared _build touched)
- Subject: smalt @ main (dda0bf5), private build root `_build-ft-cc`
- Command: `MIX_ENV=test MIX_BUILD_ROOT=_build-ft-cc mix compile --warnings-as-errors`

## Method

Clean full compile (fresh build root, both runs) under `--warnings-as-errors`
with `MIX_ENV=test`. Second run was from-scratch (`rm -rf _build-ft-cc` first)
to rule out stale-artifact masking.

## Real output (tail, from-scratch run; full log /tmp/ft-cc-compile.log)

```
==> smalt
Compiling 155 files (.ex)
Generated smalt app
```

- Exit: 0

## Warning census (awk attribution over full log)

| app | warnings |
|---|---|
| gen_state_machine | 3 (charlist deprecation x2, List.zip/1) |
| telemetry_metrics_prometheus_core | 1 (first..last match deprecation) |
| ash | 2 (Igniter.Project.Module fns undefined) |
| sweet_xml | 1 (struct update on SweetXpath) |
| ex4pm | 4 (Domain-not-present x2, GgenIgniter fns undefined x2) |
| **smalt** | **0** |

All 11 warnings are hex/path dependencies (upstream code) — no semantic-only
fix applies without patching vendored sources. `smalt` itself: zero warnings,
exit 0 under `--warnings-as-errors`.

## Cleanup

`rm -rf ./_build-ft-cc` — verified gone:

```
ls: ./_build-ft-cc: No such file or directory
```
