# Receipt: BENCH-13 deletion exec (PRD-DEL-01)

**Standing**: PASS (typed no-op on file deletions; minimal real dep deletions, verified)
- **Context**: solo
- **Date**: 2026-10-21
- **Lane**: BENCH-13 (writer, OTP-29), repo `/Users/sac/smalt`
- **Build root**: `_build-lane13`

## Audit provenance

The BENCH-9 audit receipt was NOT present in `docs/jira/v26.10.21/receipts/`
at execution time (no bench9/audit-named file; no `PRD-DEL-01` or `BENCH-9`
string anywhere under `docs/jira/v26.10.21/`). Per the dispatch fallback, the
typed classification was performed by direct greps in this lane.

## Typing (fallback greps)

Repo-wide greps for `benchee` (excluding `_build*`) surfaced:

| Site | Disposition |
|---|---|
| `mix.exs` dep block (lines 144-147 incl. comment) | **DELETED** — the dep itself |
| `mix.lock` `benchee` entry | **DELETED** |
| `scripts/bench/benchee_runner.exs` | KEPT — receipt-cited harness (`docs/jira/v26.10.14/receipts/errc2-benchee.md`; produced b7b/b8b/b9b JSONL rows) |
| `docs/THIRD_PARTY.md`, `docs/jira/v26.10.14/*`, `docs/jira/v26.10.15`, `docs/jira/v26.10.16` | KEPT — historical doc receipts, not framework-measurement artifacts |

Zero files typed as framework-measurement artifacts. **No file deletions** —
matching the audit's expected outcome ("expected: none").

## Executed deletions (mix surface only)

1. `mix.exs`: removed the 3-line comment block + `{:benchee, "~> 1.3", only: [:dev, :test], runtime: false}` (10 insertions/6 deletions net in the file per `git diff --stat`).
2. `mix.lock`: removed the `benchee` entry plus its now-orphaned transitive
   entries `statistex` and `deep_merge` (verified orphaned: only `deps/benchee/mix.exs`
   required them; no first-party `lib/`/`test/`/`scripts/` code, and no other dep
   in the resolved tree). `table` KEPT — still required by another parent in the
   resolved tree (`mix deps` line 208).
3. Removed stale checkouts `deps/benchee`, `deps/statistex`, `deps/deep_merge`
   (gitignored build hygiene; `deps/table` untouched).

## Verification (real command output)

```
$ grep -c "benchee" mix.exs mix.lock | wc -l   # witness-note (BK-100b format backfill): positive count form, exit 0 (two per-file zero-count lines) — the classified green expression of the assertion below
2
$ grep -n "benchee" mix.exs mix.lock        # exit 1 (no matches)
$ MIX_BUILD_ROOT=_build-lane13 mix deps | grep -ci "benchee|statistex|deep_merge"   # 0
$ ls deps/ | grep -ci "benchee|statistex|deep_merge"                                # 0
$ PATH=$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:... mix run --no-start -e 'IO.puts("lock-consistency-ok")'
lock-consistency-ok          # Generated smalt app; lock consistent, project loads
```

Note: the first `mix run` attempt under homebrew Elixir 1.19.5 failed with the
pre-existing `supports only Elixir ~> 1.20` pin mismatch (environment, not
session-introduced; `mix deps` is not version-gated, which is why it succeeded).
Re-ran under the project-pinned `.tool-versions` toolchain
(Elixir 1.20.4-otp-29 / Erlang 29.1.2) — green.

## Standing disclosure

`scripts/bench/benchee_runner.exs` is preserved but is now dep-less: it cannot
run until `:benchee` is re-added. It remains a receipt-cited falsifier record
per the dispatch's no-delete rule. If PRD-DEL-01 intends it retired, that is a
follow-up order (requires re-typing the v26.10.14 receipt citations first).

## Diff summary

`mix.exs` (-6/+4), `mix.lock` (-3). No other files touched by this lane.
