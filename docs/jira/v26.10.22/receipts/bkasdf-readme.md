# Receipt: BK-ASDF — README quickstart asdf pin block

- Standing: ALIVE
- Context: solo
- Date: 2026-10-22
- Lane: BK-ASDF (docs-only; closes BK-JUSTDOC gap G1's README half)
- Subject: README.md `### Bootstrap (fresh machine)` section

## What landed

README.md's quickstart (Bootstrap section, Part 2) previously jumped from
`git clone` straight to `bash scripts/bootstrap.sh` with no toolchain
acquisition — the new-engineer path hit `mix.exs`'s `elixir: "~> 1.20"`
refusal on Homebrew elixir (1.19.x) with no in-README remedy.
docs/FIRST_RUN.md already carried the correct asdf path (BK-JUSTDOC gap
G1); README.md did not. Added, content-preserving:

```sh
git clone <this-repo>
cd smalt
brew install asdf just terraform     # python3 ships with macOS / Xcode CLT
asdf plugin add elixir erlang && asdf install   # .tool-versions pins elixir 1.20.4-otp-29 / erlang 29.1.2 — Homebrew elixir (1.19.x) is refused (mix.exs: elixir "~> 1.20")
bash scripts/bootstrap.sh            # 8 idempotent stages; exit 1 names the failed [n/8] stage
```

## Verification (embedded)

`.tool-versions` (real read):

```
erlang 29.1.2
elixir 1.20.4-otp-29
asdf current: /Users/sac/smalt elixir 1.20.4-otp-29 erlang 29.1.2
```

`mix.exs:10`: `elixir: "~> 1.20"` — brew 1.19.x refused (verified by
reading the pin, the version constraint is exact).

Quickstart section audited top-to-bottom against the real Justfile —
existence probe (mechanical, `just --list` parsed, this session):

```
EXISTS up down doctor court receipts status logs bootstrap
EXISTS test-offline test-wire test-sdk-smoke tf-plan-smoke census
EXISTS test-stress court-x2 verify-all have-watchdog invariant-gates
EXISTS quiesce quiet-check
```

All 20/20 named recipes exist (T2 test-wire / T3 test-sdk-smoke are
correctly described as RETIRED exit-1 loud no-ops in the README table —
post-BK-JUSTDOC). Files named by the quickstart all exist:
`scripts/bootstrap.sh`, `scripts/gen_dev_cert.sh`, `scripts/doctor.py`,
`.env.example`. Order verified: clone → toolchain (brew + asdf) →
bootstrap.sh stages → `just up` — matches FIRST_RUN.md and
scripts/bootstrap.sh stage 1's prereq list (elixir/mix/terraform/just/
python3). No other drift found; no further edits.

## Falsifier

Any recipe above missing from `just --list`, any named script missing on
disk, or `.tool-versions`/mix.exs pin drifting from the versions named in
the README block re-opens the gap. Re-run the existence probe and re-read
`.tool-versions` + `mix.exs:10` to falsify.
