# GL-4: GraphLaw POWL business-net integration court

**Standing**: ALIVE (5/5 courts green, 4 consecutive runs, one canonical subject)
Context: solo
- **Subject**: `/Users/sac/smalt/test/integration/graphlaw_powl_business_net.exs` @ tree state 2026-10-21 (uncommitted working tree, lane build root `_build-gl4`)
- **Court file**: `test/integration/graphlaw_powl_business_net.exs`
- **Build**: `MIX_BUILD_ROOT=_build-gl4 mix test test/integration/graphlaw_powl_business_net.exs` (Elixir 1.20.4-otp-29)

## What landed

The operator's canonical order/compliance/GDPR settlement as an integration
court over the landed GraphLaw/POWL2 stack:

- SHACL guard law (HighValueOrderShape: totalAmount > 10000 requires
  complianceSignature; EU tenant requires gdprConsent; self-approval
  exclusion) as guard funs written DIRECTLY in the court — **GL-2 law
  compiler ABSENT** at write time (grep over lib/ test/ scripts/
  docs/jira/v26.10.21: zero referents, 2026-10-21). When GL-2 lands, these
  funs become its compiled output and this note retires. Disclosed per
  contract.
- POWL ChoiceGraph `enter -> validate -> [commit | compliance_review] ->
  settle -> exit` over the GL-1 seam (executor ChoiceGraph `guards` map,
  exact `ctx.last_outcome` match, `:always`/unguarded fallback), with a
  literal FOND repair edge `{enter, repair}` guarded `:andon_refused`.
- Execution via `Smalt.POWL2.Executor.execute_admitted/6` +
  `Smalt.POWL2.ChangeFeed` If-Match CAS; receipt seal via
  `Smalt.PPlan.ReceiptEngine` + `Smalt.Powl2.HsmSigner`.

## Courts

1. `$5k` no signature -> commits (`:compliant -> :committed -> :settled`),
   CAS create `{:ok, 201, etag}`, sealed receipt `phi_lease_final == step
   count`, 32-byte merkle root.
2. `$50k` no signature -> ANDON refusal
   `{:error, {:transition_failed, :validate, {:andon,
   :high_value_requires_compliance_signature}}}`; commit never fired;
   ChangeFeed ETS has no document (`etag/3 == nil`); ANDON ledger entry
   names the rule.
3. `$50k` WITH signature -> commits (`[:validate, :commit, :settle]`).
4. EU tenant, signature present, no gdprConsent -> routed to
   compliance_review, ANDON at review
   (`{:transition_failed, :review, {:andon, :eu_requires_gdpr_consent}}`);
   commit never fired; ETS unchanged.
5. FOND repair: after the refusal the court re-enters the SAME model with
   `last_outcome: :andon_refused` seeded; the guard-selected repair edge
   fires (`enter -> repair -> validate -> commit -> settle`); the order
   commits and the ChangeFeed holds the etag; the run-1 refusal stays on
   the ledger as history.

## Evidence (actual output)

```
Running ExUnit with seed: 954569, max_cases: 32
.....
Finished in 0.1 seconds (0.00s async, 0.1s sync)
Result: 5 passed
```

Three further consecutive runs: `Result: 5 passed` each (seeds 341455-class
re-draws; 4 consecutive green total).

## Compile-freeze disclosures (shared lib/, not this lane's files)

1. `lib/smalt/pipeline/smalt_fond_powl_runner.erl:180` — `R >= 0 and R =< Max`
   (`and` binds tighter than comparisons in Erlang -> syntax error). Guard
   read `andalso` on disk after my poll loop; my one-line replace script
   asserted count==1 and FAILED to write, so the landing fix is not
   verifiably mine — another lane's concurrent fix is the likely owner.
   Disclosed as unverifiable attribution, not claimed.
2. `lib/smalt/data_plane/cosmos_query_metrics.ex:75` — GL-2's owner landed
   `is_integer(x) and x >= lo and x <= hi` at ~15:33 after a 12-minute
   freeze (`:erlang.is_integer/3` does not exist as a guard); I did not
   touch the line (owner landed inside the SLA window I observed).
3. `lib/smalt/tls.ex` + `lib/smalt/wasm/worker.ex` mid-edit freezes (~2 min
   each) — owners landed; no lane action by me.

## Honest notes

- Mid-run failures persist under `{:powl2_receipt, id}` with `status:
  {:error, outcome}`; the executor's `{:powl2_refusal, id}` key is written
  only on PRE-ADMIT refusal, not mid-run. The ANDON ledger entry is
  therefore court-owned (`{:gl4_andon, id}`), asserted in courts 2/4/5.
- Executor start/end nodes are pure SESE delimiters and are never
  evaluated (a node's step is recorded when ENTERED as an edge target) —
  documented in the court moduledoc; the graph uses tau delimiters.
- OTP 29 `:dets.open_file/2` requires the `:file` option as charlist
  (binary raises ArgumentError at `dets.erl:1120`). Pinned in the court.
- Test-load-filter warning ("does not match any configured test_load
  filters") is expected: the court file has no `_test.exs` suffix per the
  lane contract; it runs by explicit path.
