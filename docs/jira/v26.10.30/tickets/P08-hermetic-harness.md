# P08 — Hermetic harness + receipt engine (the milestone gate)

- window: v26.10.30 · receipt: r-p08-harness.md
- GATE: the v26.10.30 milestone gate — the loop goal ("validate with kind
  that courtroom-platform-az works perfectly with smalt") closes when P08
  stands ALIVE.

## Claim

One command boots the full in-cluster topology (substrate + app + browser
runner), executes P01-P07, and emits a standing-line manufacturing receipt
with embedded evidence: raw command invocations + exit codes, artifact
digests, per-claim breakdown — schema-compliant with the window receipt law
(`ALIVE` only on full-flow validation; `PARTIAL_ALIVE`/`FAILED` typed).
Laws, not design: fully hermetic (zero outbound calls to any Microsoft/cloud
endpoint — hermeticity itself asserted, fail on any attempted egress);
deterministic locators/listeners only (fixed-sleep assertions banned per the
no-sleep doctrine); failure artifacts (traces, HAR) retained with digests;
execution-window budget enforced.

## Falsifier

A receipt without embedded real output, a suite that passes over a vacuous
assertion, or any cloud egress.
