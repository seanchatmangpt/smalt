# r-corpus-fence-court-witness

Standing: **PASS** (non-vacuous; restore byte-exact).

- Court: `scripts/shim_court/corpus_fence_court.sh` (exit 0)
- Subject: `lib/smalt/arm_gateway/router.ex`, baseline sha256
  `967c9567194077d29598d4d385cbf7bbe6cbaade0f61c461f692be50ddefa44f`
- Witness date: 2026-10-17, lane I20, individual court run
  (`timeout 480 bash scripts/shim_court/corpus_fence_court.sh`; the
  aggregate `just shim-courts` serializes identically per court).
- Closes the FINAL.md "corpus_fence fully unwitnessed" gap.

## Embedded output

```
[self-check] sha256 restore-detection verified
[SHIM] baseline sha256(/Users/sac/smalt/lib/smalt/arm_gateway/router.ex) = 967c9567194077d29598d4d385cbf7bbe6cbaade0f61c461f692be50ddefa44f
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to /Users/sac/smalt/lib/smalt/arm_gateway/router.ex (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] corpus_fence_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```
(exit 0)

Falsifier exercised: the AFTER flip ran against the shimmed router — the
fence holds on the landed file and the shimmed file shows the new (refusing)
outcome; a court that could not flip would have exited 1.
