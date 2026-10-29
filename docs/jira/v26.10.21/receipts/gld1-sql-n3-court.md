# GLD-1 — SQL-Ingestion + N3 Business-Rule Court (SQLD-2 projection)

**Standing:** PASS
Context: solo · Date: 2026-10-21 · runtime reports Elixir 1.19.5 / OTP 29 (stack frames: `(elixir 1.19.5)`, `stdlib 7.2`)
Lane: GLD-1 · Milestone: v26.10.21
Subject: `test/integration/gld1_sql_n3_court.exs` + pinned fixture `test/integration/fixtures/gld1/orders_dump.sql` (sha256 `c5c65bd153391752d05a56b3d9311a0492d90f21e44da4d28a82637afeed1990`)

## What the court proves

The graphlaw value on the ingestion path: N3 business rules applied over
ingested SQL data, dual-governed. One PostgreSQL dump (SQLD-2's projection),
two independent derivations, exact agreement:

```
pg dump (sha-pinned) -> COPY->INSERT transform -> real duckdb CLI ingest
  -> window/aggregate pushdown (1h rolling event window per customer)
  -> CSV projections (customers, orders, events, windows, ambiguous)
  -> N3 forward-chaining FIXED-POINT over {s,p,o} triples
  -> exact partition equality vs independent Elixir re-derivation
```

## Rule set (sealed literals: high-value > 1500; window 3600s > 3 events; credit >= 1500)

| rule | premises | conclusion |
|---|---|---|
| r1 | order amount > 1500 | `highValueOrder` |
| r2 | `highValueOrder` + `orderCustomer` | `hasFlaggedOrder(customer)` |
| r3 | `eventType payment_excursion` | `slaBreachEvent` (SLA typed) |
| r4 | `slaBreachEvent` + `eventOrder` + `orderCustomer` | `hasBreach(customer)` |
| r5 | `windowCount > 3` in 1h | `suspicious` (task's ">3 events in 1h" rule; honestly EMPTY on this corpus — max window count is 1) |
| r6 | `hasBreach` + `creditLimit >= 1500` | `suspicious` |
| r7 | `suspicious` + `hasFlaggedOrder` | `escalated` (chained — consumes only rule-derived facts) |

## Result (three consecutive runs, two processes, identical)

```
GLD-1 COURT: PASS
corpus: %{events: 80, customers: 120, orders: 300}
highValueOrder 65 · hasFlaggedOrder 48 · slaBreachEvent 26 · hasBreach 25
suspicious 21 (all via r6; r5 window rule fires on 0 customers — both legs agree empty)
escalated 12 (min derivation iteration 4, max fixed-point iteration 4)
derived facts: 197
audit_hash: c1a304d633a7f3c736af1d6de260f51f82836151342745ce6880b6378d7f090f
```

## Court legs

1. **SHA pin**: fixture sha256 asserted before any run; mismatch raises.
2. **Real duckdb ingest+projection** (CLI v1.4.1): faithful COPY→INSERT
   transform of the pg dump text (never interprets business fields), schema
   `public`, TIMESTAMP ingest, correlated window self-join pushdown.
3. **Sealed-corpus ambiguity zero**: ambiguous.csv empty on the pinned dump.
4. **Dual governance**: exact set equality on all 6 positive predicate
   classes between the duckdb→N3 engine and the independent Elixir
   re-derivation (computed from the parsed dump with comprehensions; shares
   NO rule code, NO duckdb output, NO fixed-point machinery).
5. **Fixed-point non-vacuity**: `escalated` derives at iteration 4 (r7
   consumes only rule-derived facts), so one-pass execution cannot produce
   the partition; convergence asserted.
6. **Fail-closed ambiguity**: dangling customer FK → typed
   `ambiguousCustomer`/`unknownCustomer`/`manualReview` facts; ambiguous
   subjects are structurally excluded from all positive classes (asserted).
7. **Tamper non-vacuity**: (a) amount flip on O-2 flips the partition AND
   the pipeline matches the re-derivation on the tampered corpus; (b) O-3
   repointed at unknown C-999 → typed ambiguous + manualReview, excluded
   from positives; (c) truncated ingest script → real duckdb exits 1 →
   surfaced as court failure, never a silent pass.
8. **Determinism**: sealed re-run inside the court (facts + audit hash) plus
   a separate-process re-run with identical audit hash.

## SQLD-2 bounded poll

Bounded poll (15 min, 20s interval) over `docs/jira/v26.10.21/receipts/sqld*`
+ `tmp/sqld2/`. SQLD-2's projection landed at 16:32:18 into the poll window
(`tmp/sqld2/orders_dump.sql` + `expected_counts.terms`: customers 120,
order_events 80, orders 300 — matches the ingested row counts exactly). The
dump was pinned as a court fixture (sha256 above); the synthetic fallback
corpus was discarded when the real projection landed.

## Findings during the run (honest log)

- **Elixir pipe-precedence defect caught mid-court**: `a ++ b ++ ... ++ x |> f |> g`
  parses as `((a ++ b ++ ...) ++ x) |> f |> g` (`|>` binds LOWER than `++`),
  so the whole accumulated fact list was being piped through the
  dangling-customer `Enum.filter` and base_facts silently returned `[]`.
  Surfaced as a FunctionClauseError two functions away from the defect.
  Fixed with explicit parens; the court now re-derives the full partition
  independently, so this class of silent-empty ingestion failure would fail
  Leg D loudly (mismatch, not empty-pass).
- duckdb CLI has no psql `\copy` — projection uses SQL `COPY ... TO` in a
  `-f` script.
- The task's example rule ">3 events in 1h" fires on ZERO customers of the
  SQLD-2 corpus (hourly event timestamps; max 1-in-1h). Both derivations
  agree on empty and the window pushdown is real (duckdb self-join), but the
  suspicious class is populated solely by r6 (breach ∧ high credit). This is
  recorded rather than papered over with a stretched window.
- Court runs with plain `elixir` (stdlib + duckdb CLI only), same
  concurrent-lane rationale as COLD-1: immune to in-flight lib/ edits.
