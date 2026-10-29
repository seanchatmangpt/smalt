# Receipt: BK-JUSTDOC — Justfile/doc audit for the new-engineer path

- Standing: PARTIAL_ALIVE (doc fixes landed; retired-subject successor harnesses remain not-landed — V261019-08/09)
- Context: solo
- Date: 2026-10-22
- Lane: BK-JUSTDOC (read-only + docs-only)

## Scope

Audit every engineer-facing `just` recipe and doc claim against the actual
justfile, for the goal "engineer runs the Justfile and gets the Azure emulator
running + SDKs working." Docs-only lane: only docs/ + this receipt written;
no scripts/lib touched.

## 1. Enumerate: real `just --list`

Recipe namespace = root `justfile` (284 lines) + 46 modules imported from
`justfile.d/*.just` (2611 lines total). Real `just --list` captured this
session: 150+ recipes, sections Diagnostic / Substrate Lifecycle / Code
Generation / Verification Ladder / Benchmarks & Stress / Aggregate Gates /
First Run / plus imported modules. Embedded command output:

```
Available recipes:
    apply fixture="scripts/tf_fixtures" tier="native" ...
    bootstrap      # Exit 0 green / 1 stage failed / 2 missing prereqs.
    doctor         # Exit 0 healthy / 1 finding. ~2s.
    down           # Stop the substrate via the pid file. Idempotent; exit 0 either way. ~0s.
    logs           # Tail the newest substrate log under tmp/ (follow; Ctrl-C to stop). ~0s.
    relay-env      # Print/exports the canonical relay session environment (loopback only)
    sdk-all        # ... retired members exit 1, so sdk-all is honestly red).
    sdk-census     # ---- sdk-census ----
    sdk-py         # ---- sdk-py ----
    sdk-ts         # ---- sdk-ts ----
    sdk-ts-court   # ... until they land; until then they exit 1 loudly — never a silent pass.
    status         # Exit 0 always (report-only; never fails on a stopped substrate). ~1s.
    substrate-down # ... verify all ports free. Exit 0 all free / 1 port still held.
    substrate-status # ... Exit 0 always (report-only).
    substrate-up   # Exit 0 up / 2 boot failure / 3 lock not acquired. ~5-90s.
    test-offline   # T1: offline unit suite (mix test). Exit 0 pass / nonzero on failure. ~1-3m.
    test-stress
    test-budget    # Enforce: fresh export + fail-closed gate against the seeded manifest.
    test-wire      # ... this recipe is a LOUD no-op (exit 1) until its successor lands ...
    up             # Ctrl-C to stop. Exit 0 while running.
    ... (150+ rows; full listing reproduced above in-session)
```

Existence probe (mechanical, this session):

```
EXISTS: azsim-sdk quiet-check quiesce ws-lint relay-env bootstrap doctor status
EXISTS: logs up down substrate-up substrate-down sdk-ts sdk-py sdk-all sdk-census
EXISTS: court court-x2 verify-all test-offline test-wire test-stress test-budget sdk-ts-court
MISSING: have-self-check
```

(`cli-test` and the other `justfile.d/03-cli-wiring.just` recipes are marked
`[private]`, so `just --list` hides them but `just cli-test` works — real, not
missing.)

Per-recipe verdicts (engineer-facing set):

| Recipe | Exists | Help matches behavior | Prereq holds |
|---|---|---|---|
| `bootstrap` | YES | yes (8 stages, exit 0/1/2) | needs elixir/mix/terraform/just/python3; pinned by `.tool-versions` |
| `up` / `down` | YES | yes (foreground, `/tmp/smalt.pid`) | global collision point — doc says use substrate-* for lanes |
| `substrate-up/down/status` | YES | yes (exit 0/2/3 / 0/1 / report-only) | scripts/substrate.sh exists |
| `doctor` | YES | yes (exit 0/1, ~2s) | scripts/doctor.py exists |
| `relay-env` | YES | yes; emits SMALT_ARM/EGRESS/AMQP, TLS paths, AZURE_* plan, cheat sheet | WARNs loudly if verification/ts node_modules absent |
| `sdk-ts/sdk-census/sdk-py/sdk-all` | YES | yes — all RETIRED, exit 1 loudly (64f6099) | successors V261019-08/09 not landed |
| `sdk-ts-court` / `sdk-py-court` | YES | yes — RETIRED exit 1 | same |
| `court` | YES | yes (help names the census-RED honesty clause) | bench-check needs fresh `just bench` receipt on perf change |
| `court-x2` | YES | yes (~8 min two-green) | precondition: `just quiesce`/`quiet-check` |
| `verify-all` | YES | yes (offline stages via scripts/verify_all.sh) | none |
| `test-offline` / `test-wire` / `test-sdk-smoke` / `test-stress` / `test-budget` | YES | yes; wire+sdk-smoke RETIRED exit 1 | stress needs `--include stress` |
| `status` / `logs` / `receipts` | YES | yes, report-only | none |
| `census` | YES | yes (verification/ts census.test.cjs, exit 0/1) | node + live AMQP substrate |
| `quiet-check` / `quiesce` | YES | yes (fail-closed / warm-up) | none |
| `have-self-check` (named in README) | **NO** | — | README row fixed to `just have-watchdog` (real: 0 quiet / 1 alerts / 2 config) |

## 2. Doc claims audit

### smalt/CLAUDE.md Commands

- All named recipes exist (`cli-test` is `[private]` but real).
- **DEFECT (fixed)**: test-ladder line advertised `just sdk-ts / sdk-census /
  sdk-py / sdk-all` as "real-Azure-SDK probes; exit 0 pass / 1 fail / 2
  substrate down / 3 SKIP" — all four are RETIRED (test/sdk-* deleted at
  64f6099) and always exit 1 until verification/ts+py land. This contradicted
  the paragraph 10 lines above it that correctly said sdk-ts exits 1.
- **GAP (fixed)**: no toolchain pin note (asdf elixir 1.20.4-otp-29 / erlang
  29.1.2; Homebrew elixir 1.19.x refused by the pin), no CLI profile /
  SMALT_CLI_LANE note, no KD-15 automatic-handshake note. Added after the
  Env setup block.

### README.md

- **DEFECT (fixed)**: Courts ladder T2/T3/T5/T6 rows named deleted subjects
  (`mix test test/wire`, `test/sdk-smoke/census-run.mjs`, `mix test
  test/chaos`) as live tiers; T2/T3 are RETIRED exit-1 recipes. Repointed T5
  to the landed `just census`, T6 to `just test-stress`.
- **DEFECT (fixed)**: `just have-self-check` does not exist (missing from
  `just --list`, no recipe in justfile or modules). Row repointed to the real
  `just have-watchdog`.
- **DEFECT (fixed)**: "SDK probe harness environment" section instructed
  engineers to run `node test/sdk-smoke/run.mjs` — subject deleted at
  64f6099. Section rewritten as RETIRED + successor pointer.
- **DEFECT (fixed)**: azsim-sdk row + "azsim tier" section described
  `test/sdk-full/azb20/` and `test/azsim/` as live — both deleted at
  64f6099. Both retyped RETIRED.
- Dated Standing block (2026-10-18) left as-is: self-labeled as-of-date,
  not a quickstart claim.

### docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md

- **No quickstart section exists** — the audit's quickstart claim does not
  apply; the doc is a gate ledger + path verification + seal condition. Every
  recipe it names (`just bkvc-court`, `receipt-index`, `docs-dod-check`) was
  existence-checked OK. `just docs-dod-check` re-run after all edits: exit 0
  (793 cites, 7 typed-gap skips — all pre-existing, in FINAL-RELEASE itself).

### Env vars named in docs — verified real

| Var | Verdict | Evidence |
|---|---|---|
| `SMALT_ARM` / `SMALT_EGRESS` / `SMALT_AMQP` | REAL | `smalt-cli/smalt_cli/config.py` (env > profile > defaults, ADR-PY-001); relay-env emits them |
| `SMALT_PLANES` | REAL | `lib/smalt/planes.ex:59`, `lib/smalt/config.ex:367` |
| `SMALT_DEV_PLANE` | REAL | workspace ingest gate (KD-173C2 receipt: live 503 off dev plane / 202 on `SMALT_DEV_PLANE=1`) |
| `SMALT_INGEST_HMAC_KEY` | REAL | `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md:188,199` (unset -> gate verifies default-key refusal off dev plane) |
| `NODE_EXTRA_CA_CERTS` | REAL | CLAUDE.md auth section + receipts (r231, azb-08/20, burn harnesses) — `.smalt/tls/ca-cert.pem` |
| `SMALT_CLI_CONFIG` / `SMALT_CLIENT_ID` / `SMALT_CLIENT_SECRET` | REAL | `smalt-cli/smalt_cli/profile.py:29,78-79` |
| `SMALT_CLI_LANE` | REAL | receipts bkconf-private-ports.md:20, bkwirec-cosmetics.md:31, bkexwv:13 (per-lane profile namespacing); no lib/ reader — CLI/profile-layer only |
| `SMALT_SDK_ROOT` / `SMALT_REPO` | REAL (contract) | harness deleted at 64f6099; contract documented for successor |

### Ports — match config

9443 ARM / 9444 ARM-TLS twin / 8443 egress / 5672 AMQP / 5673 Event Hubs /
9545 MCP: README plane table cites `lib/smalt/config.ex` keys; relay-env +
`smalt-cli/smalt_cli/config.py` (9443/8443/5672, ADR-PY-001) agree. Consistent
across CLAUDE.md, README, justfile `PORTS := "9443 9444 5672 5673"`.

## 3. New-engineer gaps (typed, with fix — all landed)

1. **Toolchain pin unstated** — GAP(doc-toolchain): `.tool-versions` pins
   elixir 1.20.4-otp-29 / erlang 29.1.2 via asdf; Homebrew elixir (1.19.x) is
   refused by the pin, and `just docs/FIRST_RUN.md` told engineers to
   `brew install elixir`. Fix: FIRST_RUN.md rewritten to `asdf plugin add
   elixir erlang && asdf install`; CLAUDE.md Env setup gains the pin note.
2. **NODE_EXTRA_CA_CERTS for SDK TLS** — was stated only in the auth-mode
   paragraph; now explicit in CLAUDE.md env context (SDK legs ride the 9444
   TLS twin with `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`).
3. **SMALT_CLI_LANE** — parallel CLI sessions namespace per-lane profile
   state via `SMALT_CLI_LANE=<name>` (receipt-evidenced, profile layer).
   Documented in CLAUDE.md.
4. **CLI profile** — `~/.smalt-cli/config.json` persists endpoints (env >
   profile > defaults, `smalt-cli/smalt_cli/profile.py:29`,
   `SMALT_CLI_CONFIG` overrides). Documented in CLAUDE.md.
5. **KD-15 handshake is automatic** — the KV corpus 401-challenge handshake
   is performed by the Azure SDKs' ChallengeAuthPolicy; no manual step.
   Documented in CLAUDE.md (prevents engineers hand-rolling tokenless-only
   clients — the premise-rot class from r239/r240).

## Files touched (all docs/)

- `CLAUDE.md` — sdk probes line retyped RETIRED; toolchain/CLI-profile/
  SMALT_CLI_LANE/KD-15 paragraph added after Env setup.
- `README.md` — courts ladder T2/T3/T5/T6 + have-watchdog rows; azsim-sdk
  row; SDK probe harness section; azsim tier section.
- `docs/FIRST_RUN.md` — brew-elixir quickstart replaced with asdf pin path.
- This receipt.

## Verification

- `just --list` real output captured before edits; existence probe for all
  named recipes (1 MISSING found: have-self-check).
- `just docs-dod-check` after edits: exit 0 — `kd-receipt-fence: checked 793
  receipt cites ... (461 cites, 7 typed-gap skips) -> OK` (all 7 skips
  pre-existing typed gaps in FINAL-RELEASE-26.10.22.md, none introduced).

## Falsifier

A doc-claim defect remains if any recipe named in CLAUDE.md Commands, README
courts ladder, or FIRST_RUN is absent from `just --list` (or is RETIRED while
described as live), or any named env var has no reader in lib/ + scripts/ +
smalt-cli/. Re-run the existence probe + greps above to falsify.
