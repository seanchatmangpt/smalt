# BK-44 — `just witness-all` fail-closed receipt re-witness gate (closes BK-8)

**Standing:** PARTIAL_ALIVE (gate authored + exercised for real: full-corpus dry-run, bounded 10-receipt mix-test subset 8 green / 2 typed environmental reds; the full gated run is owed by the wrap lane)
Context: solo
Date: 2026-10-21
Lane: BK-44 (BK-8 typed "`just witness_all does not exist`" — the terminal gate names it, so author it)

## Surface

- `scripts/witness_all.py` — canonical walker (new)
- `justfile.d/44-witness.just` — recipes `witness-all-dry` / `witness-all` / `witness-all-mix` (new)
- `justfile` — single import line added at the end of the import block (root was clean pre-edit — `git diff justfile` empty before my edit; concurrent lanes' imports landed adjacent, both intact)

## Design (fail-closed, no fake passes)

`scripts/witness_all.py` walks `docs/jira/v26.10.21/receipts/*.md` (INDEX.md excluded) and for each receipt:

1. Requires an explicit `Standing:` line — missing => `[WITNESS-FAIL] <receipt> NO-STANDING` typed line, counts toward exit 1.
2. Extracts candidate commands from fenced code blocks and `$ `-prefixed lines (trailing `# comment` suffixes stripped).
3. Classifies fail-closed against a whitelist; anything not matching is a loud `[WITNESS-STALE] <receipt> <reason>` line — never a silent skip:
   - `mix test <files>` file-scoped with existing .exs targets → re-run for real with `MIX_BUILD_ROOT=_build-witness` and the asdf-pinned toolchain (elixir 1.20.4-otp-29 / erlang 29.1.2 read from `.tool-versions`; ambient homebrew elixir 1.19.5 fails the `~> 1.20` mix.exs gate).
   - `just <recipe>` allowlist: doctor / status / receipts / logs / docs-dod-check / sleep-gate / receipt-index / invariant-gates.
   - `python3 scripts/…` verification scripts (kd_flip.py read-only; `--apply`/`--force` refused).
   - read-only tools (grep/jq/cat/ls/wc/head/tail/sha256sum) over existing files.
   - cargo test under the graphlaw checkout (`GRAPHLAW_ROOT` env override, default sibling canonical checkout).
4. Re-run exit 0 => `[WITNESS-GREEN]`; non-zero or timeout => `[WITNESS-RED]`.
5. Exit 1 on any red or NO-STANDING; summary always printed (total / witnessed-green / stale-typed / failed).

## Real runs

### Dry-run (full corpus)

    $ python3 scripts/witness_all.py --dry-run
    [WITNESS-SUMMARY] total=171 witnessed-green=0 stale-typed=77 failed=50 (DRY-RUN)
    [WITNESS-SUMMARY] total=185 witnessed-green=0 stale-typed=83 failed=58 (DRY-RUN)   # corpus grew as lanes landed receipts mid-session
    exit 0 (dry-run never gates — initial version let NO-STANDING receipts gate the dry-run
    exit; fixed so --dry-run lists dispositions and only a real run exits 1)

### Bounded subset — `python3 scripts/witness_all.py --class-filter mix-test --limit 10`

Run 1 — tree mid-edit by another lane (`lib/smalt/store.ex` syntax error in flight): 0 green / 10 red
(first attempt before the toolchain pin: every receipt `** (Mix) Elixir v1.19.5 ... supports only ~> 1.20`;
after the pin: store.ex CompileError). Disclosed as environmental, discarded; gate correctly exited 1 both times.

Run 2 — tree compiling, MIX_BUILD_ROOT=_build-witness, pinned toolchain, 10 receipts exercised for real:

    [WITNESS-GREEN] amqp10-court-closure.md          exit=0
    [WITNESS-GREEN] amqp10-crash-only-router.md      exit=0
    [WITNESS-GREEN] amqp10-skeptic-redispatch.md     exit=0
    [WITNESS-GREEN] armfix-top3-typed-violations.md  exit=0
    [WITNESS-GREEN] bk23-fence-repair-promotions.md  exit=0
    [WITNESS-RED]   bk25-kd92-93-cosmos.md           exit=1 — CompileError lib/smalt/egress/SyncRoutes.ex
    [WITNESS-RED]   fondrunner-court.md              exit=1 — same SyncRoutes.ex compile abort
    [WITNESS-GREEN] fondrunner-otp29-pipeline.md     exit=0
    [WITNESS-GREEN] gl3-andon-diagnostic-receipt.md  exit=0
    [WITNESS-GREEN] gl7-rule-change-rdf-edit.md      exit=0
    [WITNESS-SUMMARY] total=185 witnessed-green=8 stale-typed=83 failed=58
    EXIT=1 (fail-closed on the 2 compile-abort reds)

The 2 reds are a concurrent lane's in-flight `lib/smalt/egress/SyncRoutes.ex` edit that broke the shared
compile mid-run (compile-freeze SLA violation by that lane). Not standing regressions: 5 of the same
build root's courts ran green minutes earlier in the same run, and the manual green proof
(`test/internal/journal_reader_court_test.exs`, 15 passed) also predates the break. The gate's exit-1 on
compile aborts is the intended fail-closed semantics (BK-27 census law: a compile abort reads loudly,
never silently as a failure count).

## Falsifier status

- Dry-run lists dispositions for every receipt — MET (171→185 measured as lanes landed mid-session).
- Bounded subset executes real mix tests in a fresh lane build root — MET (8/10 green; 2 typed reds).
- Full gated run over the whole corpus — OPEN, owed by the wrap lane (BK-8 close condition).

## BK-8 close condition

`just witness-all` exists, is fail-closed, proven on real receipts. BK-8 flips to closed when the wrap
lane lands a full `just witness-all` run in the window's wrap receipt (exit 0, or exit 1 with every red
individually typed and owned).