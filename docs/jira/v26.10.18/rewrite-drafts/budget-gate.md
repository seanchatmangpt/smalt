# Rewrite draft: per-test timing budget gate

Status: DRAFT (ERRC-Create, no edits landed). Repo: /Users/sac/smalt.
Shaped after `gates/common.py` (fail-closed contract, receipt) and
`scripts/bench_check.py` (stdlib-only, receipt-in, CTQ table, exit 0/1).

## Problem

ExUnit does not emit per-test durations by default, so a regression that makes
one test hang for minutes is visible only as a slow total `mix test`. The gate
needs (a) a real per-test timing export, (b) a budget manifest, (c) a
fail-closed checker that refuses on breach, missing data, or manifest drift.

## Design

Three artifacts:

1. `test/support/budget_formatter.ex` — ExUnit formatter capturing
   `:test_finished` events (`%ExUnit.Test{...}.time` is microseconds, set by
   ExUnit itself — no monkey-patching) and writing one
   `file:line\tduration_ms\ttest-name` line per test to
   `$SMALT_BUDGET_EXPORT` (default `tmp/test-budget-export.tsv`).
2. `docs/jira/v26.10.18/test_budgets.json` — manifest:
   `{"schema": "smalt-test-budget/v1", "budgets": {"<test-id>": {"tier": "default"|"stress", "max_ms": N}}}`.
   Tier table: `stress` → 300_000 ms, `default` → 5_000 ms; explicit
   `max_ms` overrides the tier.
3. `scripts/test_budget_gate.py` — reads the export, enforces every line
   against the manifest. Exit 0 only when all pass.

### Fail-closed matrix (the point of the gate)

| Condition | Verdict |
|---|---|
| export missing / empty / malformed line | FAIL |
| manifest missing / invalid JSON / wrong schema | FAIL |
| test in export with no manifest entry | FAIL (prompt to re-seed) |
| manifest entry with no export line (test did not run) | FAIL (stale budget) |
| `duration_ms > max_ms` | FAIL (breach) |
| first run with `--seed` | seeds manifest, exit 0, prints counts |

### Non-vacuity

A gate that cannot fail is vacuous. Two self-checks, run in-process on a temp
copy of the export (mirrors `run_gate`'s mutate-fixture loop in
`gates/common.py`):

- fixture `breach`: one line's duration scaled 10x → verdict must REFUSE;
- fixture `unmanifested`: one line's test-id renamed → verdict must REFUSE.

If either mutated observation is ACCEPTED, the gate exits 1 with
`VACUOUS GATE`. Gate receipt: `tmp/test-budget-gate-receipt.json`
(`schema: smalt-test-budget-gate/v1`).

---

## Artifact 1: `test/support/budget_formatter.ex`

```elixir
defmodule SmaltTest.BudgetFormatter do
  @moduledoc """
  Per-test timing exporter for the test-budget gate
  (docs/jira/v26.10.18/rewrite-drafts/budget-gate.md).

  Usage:
      SMALT_BUDGET_EXPORT=tmp/test-budget-export.tsv \\
        mix test --formatter SmaltTest.BudgetFormatter

  Emits one TSV line per finished test:
      file:line\\tduration_ms\\ttest-name
  Durations come from ExUnit's own `time` field (microseconds) on the
  :test_finished event — no measurement of our own. Lines are flushed on
  :suite_finished so a crashed run yields a truncated (hence gate-failing)
  export, not a missing one.
  """

  # ExUnit formatter behaviour: init(config) -> {config, state};
  # handle_event(event, config, state) -> {config, state}.
  # Delegating to ExUnit.CLIFormatter preserves normal console output while
  # we tee the timing export.
  use GenServer

  def init(config) do
    path = System.get_env("SMALT_BUDGET_EXPORT") || "tmp/test-budget-export.tsv"
    File.mkdir_p!(Path.dirname(path))
    io = File.open!(path, [:write, :utf8])
    config = Keyword.put_new(config, :budget_io, io)
    # Keep the standard console behaviour alongside the export.
    {:ok, cli} = ExUnit.CLIFormatter.init(config)
    {:ok, %{cli: cli, io: io, path: path}}
  end

  def handle_event(:test_finished, %ExUnit.Test{} = test, %{io: io} = st) do
    ms = div(test.time || 0, 100)
    id = "#{test.case}:#{test.name}"
    loc = "#{test.case}" # file:line fallback; ExUnit carries position below
    line = case test.tags do
      %{file: f, line: l} -> "#{f}:#{l}"
      _ -> loc
    end
    IO.write(io, "#{line}\t#{ms}\t#{id}\n")
    {:noreply, %{st | cli: elem(ExUnit.CLIFormatter.handle_event(:test_finished, test, st.cli), 1)}}
  end

  def handle_event(event, data, %{cli: cli} = st) do
    {:noreply, cli} = ExUnit.CLIFormatter.handle_event(event, data, cli)
    if event == :suite_finished do
      File.close(st.io)
      IO.puts("== budget export written: #{st.path}")
    end
    {:noreply, %{st | cli: cli}}
  end
end
```

Draft note (land-lane to fix during implementation): the CLIFormatter
delegation above is the one stateful seam; if delegation proves brittle
across ExUnit versions, drop it and let the budget run be export-only
(`mix test --formatter SmaltTest.BudgetFormatter` with no console formatter)
— the gate consumes the file, not the console, so export-only is the
simpler Chicago-faithful fallback.

## Artifact 2: `scripts/test_budget_gate.py`

```python
#!/usr/bin/env python3
"""Per-test timing budget gate (stdlib-only; shaped after scripts/bench_check.py
and gates/common.py).

Reads the TSV timing export written by SmaltTest.BudgetFormatter
(test/support/budget_formatter.ex):

    file:line<TAB>duration_ms<TAB>case:test_name

and enforces every entry against the budget manifest
(docs/jira/v26.10.18/test_budgets.json, schema smalt-test-budget/v1):

    {"budgets": {"<case>:<test>": {"tier": "default"|"stress", "max_ms": 1234}}}

Tier budgets: stress = 300_000 ms, default = 5_000 ms; explicit max_ms wins.

Fail-closed: missing/empty/malformed export, missing/invalid manifest,
unmanifested test, stale manifest entry (test absent from export), or any
breach => exit 1. --seed records the manifest from the current export
(first-run seeding; subsequent runs enforce).

Non-vacuity: before reporting, the gate runs two mutated fixtures of the
export (10x breach, unmanifested rename) through the same verdict function;
either one ACCEPTED => VACUOUS GATE, exit 1.
"""
import argparse, json, os, sys, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXPORT = os.path.join(REPO, "tmp", "test-budget-export.tsv")
DEFAULT_MANIFEST = os.path.join(REPO, "docs", "jira", "v26.10.18", "test_budgets.json")
SCHEMA_EXPORT_LINE = 3          # file:line, ms, case:name
TIERS = {"default": 5_000, "stress": 300_000}


def parse_export(path):
    """-> {test_id: (duration_ms, location)} ; ValueError on any malformed line."""
    if not os.path.exists(path):
        raise ValueError(f"missing export: {path} (run budget formatter first)")
    out = {}
    with open(path) as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != SCHEMA_EXPORT_LINE or not parts[1].isdigit() or ":" not in parts[2]:
                raise ValueError(f"{path}:{n}: malformed line: {line!r}")
            ms, tid = int(parts[1]), parts[2]
            if tid in out:
                raise ValueError(f"{path}:{n}: duplicate test id {tid}")
            out[tid] = (ms, parts[0])
    if not out:
        raise ValueError(f"empty export: {path}")
    return out


def load_manifest(path):
    try:
        with open(path) as f:
            m = json.load(f)
    except FileNotFoundError:
        raise ValueError(f"missing manifest: {path} (seed with --seed)")
    except json.JSONDecodeError as e:
        raise ValueError(f"invalid manifest JSON: {e}")
    if m.get("schema") != "smalt-test-budget/v1" or not isinstance(m.get("budgets"), dict):
        raise ValueError(f"manifest schema mismatch, expected smalt-test-budget/v1: {path}")
    return m["budgets"]


def verdict(export, budgets):
    """-> (ok, details). Pure function of the observations: reused verbatim on
    mutated fixtures for the non-vacuity check."""
    details = []
    ok = True
    for tid, (ms, loc) in sorted(export.items()):
        b = budgets.get(tid)
        if b is None:
            ok = False
            details.append(f"UNMANIFESTED {tid} ({loc}, {ms}ms) — re-seed or budget it")
            continue
        tier = b.get("tier", "default")
        max_ms = b.get("max_ms", TIERS.get(tier))
        if max_ms is None:
            ok = False
            details.append(f"BUDGET-UNKNOWN {tid}: tier {tier!r} not in {sorted(TIERS)}")
            continue
        if ms > max_ms:
            ok = False
            details.append(f"BREACH {tid}: {ms}ms > {max_ms}ms (tier {tier}, {loc})")
    for tid in sorted(set(budgets) - set(export)):
        ok = False
        details.append(f"STALE {tid}: in manifest but absent from export")
    return ok, details


def main():
    ap = argparse.ArgumentParser(description="smalt per-test timing budget gate")
    ap.add_argument("--export", default=DEFAULT_EXPORT)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--seed", action="store_true",
                    help="record manifest from the current export (first run)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        export = parse_export(args.export)
    except ValueError as e:
        print(f"FAIL budget-gate/export: {e}", file=sys.stderr)
        sys.exit(1)

    if args.seed:
        budgets = {tid: {"tier": "stress" if ms > TIERS["default"] else "default",
                         **({"max_ms": ms} if ms > TIERS["default"] else {})}
                   for tid, (ms, _) in export.items()}
        os.makedirs(os.path.dirname(args.manifest), exist_ok=True)
        with open(args.manifest, "w") as f:
            json.dump({"schema": "smalt-test-budget/v1", "seeded": time.strftime("%Y-%m-%d"),
                       "budgets": budgets}, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"seeded {len(budgets)} budgets -> {args.manifest}")
        sys.exit(0)

    try:
        budgets = load_manifest(args.manifest)
    except ValueError as e:
        print(f"FAIL budget-gate/manifest: {e}", file=sys.stderr)
        sys.exit(1)

    # Non-vacuity: mutated observations must be REFUSED by the same verdict.
    fixtures = []
    for name, mut in (
        ("breach", {t: (m * 10, l) for t, (m, l) in export.items()}),
        ("unmanifested", {f"Vanished.Case:renamed_{t}": v for t, v in export.items()}),
    ):
        fok, fdet = verdict(mut, budgets)
        detected = not fok
        print(f"{'PASS' if detected else 'FAIL'} budget-gate/fixture:{name} "
              f"({'refused' if detected else 'ACCEPTED — VACUOUS GATE'})")
        fixtures.append({"fixture": name, "detected": detected})

    ok, details = verdict(export, budgets)
    receipt = {
        "schema": "smalt-test-budget-gate/v1",
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "export": os.path.relpath(args.export, REPO),
        "manifest": os.path.relpath(args.manifest, REPO),
        "tests": len(export),
        "verdict": "PASS" if (ok and all(f["detected"] for f in fixtures)) else "FAIL",
        "fixtures": fixtures,
        "breaches": details,
    }
    with open(os.path.join(REPO, "tmp", "test-budget-gate-receipt.json"), "w") as f:
        json.dump(receipt, f, indent=2)

    if args.json:
        print(json.dumps(receipt, indent=2))
    else:
        print(f"== Test Budget Gate == ({len(export)} tests)")
        for d in details:
            print(f"  {d}")
        print(f"Gate: {receipt['verdict']}")
    sys.exit(0 if receipt["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
```

## Artifact 3: `justfile.d/28-test-budget.just`

```just
# 28-test-budget — per-test timing budget gate (docs/jira/v26.10.18)
# Seed once, then every run enforces. Export via the budget formatter.

# Record the manifest from a fresh timing export (first run / deliberate
# budget refresh; the refresh itself is a reviewed diff, not silent).
test-budget-seed:
    SMALT_BUDGET_EXPORT={{tmp_dir}}/test-budget-export.tsv \
      mix test --formatter SmaltTest.BudgetFormatter
    python3 scripts/test_budget_gate.py --seed

# Enforce: fresh export + fail-closed gate against the seeded manifest.
test-budget:
    SMALT_BUDGET_EXPORT={{tmp_dir}}/test-budget-export.tsv \
      mix test --formatter SmaltTest.BudgetFormatter
    python3 scripts/test_budget_gate.py

tmp_dir:
    @echo tmp
```

Wiring: add `test-budget` to `scripts/verify_all.sh`'s stage table after
`test-offline` (offline stage; no substrate state). Full `mix test` is the
gate's cost — a `--only`/fast tier can be added later by exporting during
`fast_test.sh` runs; do not enforce budgets on partial exports (the
STALE-manifest check would fail-closed, which is correct behavior, not a
bug — partial enforcement needs a `--allow-stale-for` escape hatch with its
own receipt field).

## Manifest seeding procedure

1. `just test-budget-seed` — full `mix test` with the budget formatter;
   `--seed` derives the manifest: `default` tier unless a test exceeded the
   5 s default (then `stress` tier with its measured `max_ms` pinned).
2. Review the seeded `docs/jira/v26.10.18/test_budgets.json` diff — budgets
   are load-bearing constants, the seed is a proposal.
3. Thereafter `just test-budget` enforces: a regression above budget, a
   deleted/renamed test (stale entry), a new unbudgeted test, or a
   corrupted/missing export all exit 1 with a typed detail line.
4. Deliberate budget changes: edit the manifest in the same diff as the
   test change (no silent re-seed on an enforcing tree — `--seed` prints
   the count and is for bootstrap/refresh only).

## Non-goals / notes

- Flaky-timing defense is deliberately NOT in the gate: a test near its
  budget is a budget-review signal, not something to pad with hysteresis.
  Relax `max_ms` in a reviewed diff instead.
- `test.time` is wall-clock under ExUnit's async scheduler — concurrent
  contention inflates it. That is acceptable here: budgets gate the shared
  checkout's real `mix test` experience; per-test CPU accounting is a
  separate instrument.
- Formatter placement in `test/support/` follows the existing
  `SmaltTest.*` helper convention (see `test/support/tp_oracle`).
