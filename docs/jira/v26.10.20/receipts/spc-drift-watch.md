# SPC Drift Watch — scvd_tier1 continuous ground-truth watch (C09 increment)

- **Standing:** **PARTIAL_ALIVE** (typed DRIFT verdict emitted; load-confounded — see Confound)
- Context: full
- Date: 2026-10-21
- Subject: `/Users/sac/smalt/tmp/bench/scvd_tier1.mjs` (tier-1, 16 legs × 5 cycles, live substrate on 127.0.0.1:9444 TLS twin, KD-15 STS bearer minted per round)

## Method

6 rounds spaced ~3.5 min (18:19Z–18:37Z). Baseline = rounds 1–4, band = mean ± 3×MAD per metric; rounds 5–6 flagged if outside. All 6 rounds executed with harness verdict PASS and `errors: 0` — the DRIFT is an SPC band excursion on throughput/latency, not a correctness failure and not a harness SKIP.

## Rounds (from `/Users/sac/smalt/tmp/bench/spc-watch.jsonl`)

| round | ts (UTC) | ops/s | p99 ms | errors |
|---|---|---|---|---|
| 1 | 18:19:25 | 2355.9 | 18.326 | 0 |
| 2 | 18:22:56 | 2406.5 | 18.471 | 0 |
| 3 | 18:26:26 | 2174.2 | 20.067 | 0 |
| 4 | 18:29:56 | 2145.9 | 20.704 | 0 |
| 5 | 18:33:27 | 1907.6 | 19.24 | 0 |
| 6 | 18:36:57 | 1646.1 | 26.653 | 0 |

## SPC bands (baseline rounds 1–4)

- ops/s: mean 2270.6, MAD 110.6, band [1938.9, 2602.4] — round 5 (1907.6) and round 6 (1646.1) BELOW band
- p99: mean 19.39, MAD 0.99, band [16.41, 22.37] — round 6 (26.65) ABOVE band

## Verdict

**DRIFT** (typed). Two metrics, three flagged points across rounds 5–6.

## Confound (honest caveat)

Machine load average at watch close: **24.53** (1-min) on 16 cores, `uptime` 11:37 local — concurrent lanes were loading the box while rounds 5–6 ran. The DRIFT verdict stands as emitted (the rule is mechanical), but the excursion is plausibly host-load-confounded, not a substrate regression. Substrate stayed UP the whole window (pid 8877, lock FREE, recheck at close). Follow-up: re-run the 6-round watch when load < 8 to disambiguate host-load vs substrate drift.

## Receipts

- Result jsonl (rows + verdict row): `/Users/sac/smalt/tmp/bench/spc-watch.jsonl`
- Harness: `/Users/sac/smalt/tmp/bench/scvd_tier1.mjs` (run as `NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem node tmp/bench/scvd_tier1.mjs`; bare run fails TLS leaf verification — loud)
- Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- Errors: none in any round; verdict row appended at 18:37:15Z

## Addendum — disambiguation re-run attempt (2026-10-21, SPC2 lane) — SKIP (typed, load-gate)

- **Standing:** **SUSPECT** (disambiguation NOT executed; original DRIFT verdict remains load-confounded and unresolved)
- Context: solo
- Gate: re-run only when 1-min load < 8; 3 checks spaced 5 min, SKIP if all ≥ 8.
- Load checks (all ≥ 8, rising): 18:38Z = **33.32**, 18:44Z = **37.45**, 18:49Z = **40.30** (`uptime`, Apple M3 Max, 16 cores). Gate never opened — watch not run, window not burned.
- Substrate: UP the whole attempt (beam.smp pid 8877, LISTEN 127.0.0.1:9444). No substrate-down SKIP.
- No rounds executed, no new SPC bands computed, no verdict flip. Original DRIFT (rounds 5–6 below ops/s band, round 6 above p99 band) stands as emitted with its load-confound caveat.
- Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- Result jsonl: `/Users/sac/smalt/tmp/bench/spc-watch2.jsonl` (single SKIP row). Retry condition unchanged: 1-min load < 8 at each round start.
