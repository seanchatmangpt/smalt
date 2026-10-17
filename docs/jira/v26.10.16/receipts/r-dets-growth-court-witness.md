# r-dets-growth-court-witness

Standing: **PASS** (non-vacuous; restore byte-exact).

- Court: `scripts/shim_court/dets_growth_court.sh` (exit 0)
- Subject: `lib/smalt/store/dets_mirror.ex`, baseline sha256
  `03fef53cdee98133bce10d4cd37524894c802457dd70769a76a980f2c4667a5c`
- Witness date: 2026-10-17, lane I20, individual court run
  (`timeout 480 bash scripts/shim_court/dets_growth_court.sh`).
- Closes the FINAL.md "dets_growth session-witnessed only, witness receipt
  PENDING" gap (D5 re-scope).

## Embedded output

```
[self-check] sha256 restore-detection verified
[SHIM] baseline sha256(lib/smalt/store/dets_mirror.ex) = 03fef53cdee98133bce10d4cd37524894c802457dd70769a76a980f2c4667a5c
==> ex4pm (pre-existing upstream sync warnings, unrelated to the court)
==> smalt
Compiling 11 files (.ex)
Generated smalt app
13:16:57.947 [info] Running Smalt.ArmGateway.Router with Bandit 1.13.1 at 127.0.0.1:58039 (http)
13:16:57.999 [info] Running Smalt.Application.TlsTwinDispatch with Bandit 1.13.1 at 127.0.0.1:58040 (https)
13:16:58.006 [info] Running Smalt.EgressRouter with Bandit 1.13.1 at 127.0.0.1:58041 (http)
13:16:58.009 [info] Running Smalt.Mcp.Router with Bandit 1.13.1 at 127.0.0.1:58044 (http)
13:16:58.012 [info] [amqp] sb listener bound on port 58042
13:16:58.012 [info] [amqp] eh listener bound on port 58043
Running ExUnit with seed: 38199, max_cases: 32
Excluding tags: [:amqp_wire]
..
Finished in 0.06 seconds (0.00s async, 0.06s sync)
2 tests, 0 failures
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/store/dets_mirror.ex (SHIM-COURT marker present)
[SHIM] AFTER: growth census FAILED under shim as required (200-vs-100 leak witnessed; flip confirmed, see /tmp/dets_growth_after.log)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] dets_growth_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
```
(exit 0)

Falsifier: under the shim the growth census refuses (200-vs-100 leak
witnessed) — the flip, not the shim's presence, is the proof.
