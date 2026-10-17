# Receipt: r232 — 80/20 ERRC Analysis & Verification

- **Lane:** ERRC / 80/20 Scope Evaluation
- **Date:** 2026-10-17
- **Standing:** PASS

## Summary

This receipt documents the 80/20 ERRC (Eliminate, Reduce, Raise, Create) audit and verification pass performed against `smalt`.

## 80/20 ERRC Grid

| Category | Item / Surface | Verification / Action | Standing |
|---|---|---|---|
| **Eliminate** | `scripts/tf_provider_wrap.sh` kill-or-wire evaluation | Checked inbound calls across repo. Active callers verified: `scripts/smalt-tf` (line 120), `scripts/bench/c11_tf_loop.sh` (line 406). **RETAINED** (do not kill; script is wired for zero-dialog plugin env). | VERIFIED-WIRED |
| **Eliminate** | Scratch bench logs (`docs/tmp/bench-substrate-*.log`) | Checked `docs/tmp` directory on disk. Verified directory is empty and ignored. | VERIFIED-CLEAN |
| **Reduce** | Scope trim across Azure surfaces | Verified 80/20 scope trims documented in `docs/explanation/emulation-stance.md`: Cosmos SQL AST, SB subscription rules, Policy/RBAC. | VERIFIED-DOCUMENTED |
| **Raise** | Security / Property testing & Benchmarks | Verified Sobelow static analysis integration (`justfile.d/20-sobelow.just`), property-based test suites (`smalt-cli/test_hw_property.py`), Benchee benchmarks (`scripts/bench/benchee_runner.exs`), HDR histograms (`b2b_blob_hdr.mjs`, `b3b_cosmos_hdr.mjs`). | VERIFIED-ACTIVE |
| **Create** | ERRC Execution Receipt | Created `docs/jira/v26.10.16/receipts/r232-80-20-errc-analysis.md` and updated `docs/jira/v26.10.16/next-window-errc.md`. | PASS |

## Verification Command Output

```bash
$ grep -rn "tf_provider_wrap.sh" .
./docs/jira/v26.10.16/receipts/bench-c11-tf-loop.md:18:(receipt-revalidated) → post-init provider wrap
./scripts/smalt-tf:120:  bash "$ROOT/scripts/tf_provider_wrap.sh" >&2 || true
./scripts/bench/c11_tf_loop.sh:406:  bash "$ROOT/scripts/tf_provider_wrap.sh" >"$WORK/provider-wrap.log" 2>&1
```

```bash
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
```

## Conclusion

All 80/20 ERRC candidates verified. `scripts/tf_provider_wrap.sh` confirmed wired and retained. Receipt indexes updated.
