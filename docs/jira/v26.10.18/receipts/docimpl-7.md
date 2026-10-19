# docimpl-7 — docs-audit D5 (C1-C7) implementation receipt

Standing: PARTIAL_ALIVE (all D5 findings implemented; counts re-measured at HEAD)
Context: solo(docs-audit D5 C1-C7 verification greps + just docs-dod-check; no mix test invocation)

Subject: docs-audit findings `docs/jira/v26.10.18/docs-audit/d5-compliance-azsim.md`
C1-C7, applied to the seven compliance registers in `docs/compliance/` at
smalt HEAD 6681746. No git actions performed (coordinator owns transitions).

## C1 — C1_ARM_REST.md

- Line citations refreshed against `lib/smalt/arm_gateway/router.ex` at HEAD:
  `send_arm_error/4` -> `router.ex:531-560`; request-id/throttle plugs wired at
  `router.ex:53-54` with bodies `:101` / `:132` (row 11 + row 12);
  `handle_rg_delete/2` -> `router.ex:708`; `check_version/3` ->
  `router.ex:1947-1949`; poll route -> `router.ex:2607`; envelopes -> 660-671 /
  1075-1084; sync PUT -> 805-874 / 618-677; async headers -> 2139-2146;
  api-version gate -> 1923-1936; latest-version message -> 1985-1991;
  case-insensitive segments -> 2630-2651; `find_admitted/1` -> 2124-2128;
  list envelopes -> 433-452 / 609-616 / 411; content-type -> `router.ex:186`.
- LRO one-writer mechanism note added (new section "LRO one-writer mechanism
  (v26.10.18 redesign)" before "## Fenced surface", plus row 5 / row 5b and the
  GAP-register pin refresh): Sweeper is the SINGLE terminal writer, the only
  flip-path invoker of public `evaluate/2`/`fail_closed/2` (`lro.ex:378-423`);
  `get_op/1` is a pure reader routing persistence through the writer
  (`lro.ex:70-107`); `fail_closed_via_writer/2` at `lro.ex:323`; writer
  messages `{:flip_due, _}` / `{:fail_closed, _, _}` (`lro_sweeper.ex:73-88`).
  The superseded "evaluate/1 lazy-persist" description is marked as such.
- Canonical resilient_clear setup note added to Method (c1 variant:
  `SmaltTest.Store.resilient_clear/1`, `test/support/store_resilient.ex`, with
  `post_seed` inside the retry window).

## C3 — C3_COSMOS.md

- Canonical resilient setup documented in Method:
  `Smalt.Corpus.Helper.resilient_clear/1` (`test/corpus/helper.exs`), bounded
  typed retry 50 x 10ms rescuing only the dead-table ArgumentError, i21/i22
  hardening (v26.10.17 i21-ets-race-fix receipt); private copies deleted.

## C4 — C4_BLOB.md

- Test count re-measured 42 -> 49 (lens-6 x-ms-range/Range precedence +
  ranged-HEAD courts, lens-5 request-id/conditional-write fence blocks landed
  post-measure); re-measure command is the compliance loader, not the
  standalone file (standalone `mix test test/compliance/c4_blob.exs` fails at
  HEAD because `Smalt.Corpus.Helper` is loaded by the loader — measured:
  `49 tests, 49 failures`, all `Smalt.Corpus.Helper.resilient_clear/0 is
  undefined`; replay through `mix test test/compliance_test.exs`).

## C2 / C5 / C6 / C7 — loci-drift-only pin refresh (assertions preserved)

- C2_KEYVAULT.md: 15 pins refreshed (key_vault_actions.ex / skr.ex /
  attestation.ex / egress_router.ex).
- C5_SERVICEBUS.md: 22 pins refreshed (frame_codec.ex / primitive_codec.ex /
  connection.ex / delivery_encoder.ex).
- C6_OAUTH_OIDC.md: 11 pins refreshed (arm_gateway/router.ex / bearer.ex).
- C7_EVENT_PLANES.md: 8 pins refreshed (event_stream.ex / event_hubs.ex /
  purview_atlas.ex / arm_gateway/router.ex).
- All compliance-row standings, GAP tokens and prose assertions preserved
  verbatim; only `file.ex:NN` loci changed.

## Re-measure (real output)

```
$ mix test test/compliance_test.exs
...
Finished in 9.0 seconds (0.00s async, 9.0s sync)
157 tests, 0 failures (16 excluded)
```

Register fence inside that run asserts per-file counts equal the loader
register (c1=26, c2=16, c3=28, c4=49, c5=16, c6=18, c7=17) — the inventory
test passing witnesses the 49 count.

```
$ just docs-dod-check
...
OK    README.md
$ echo $?
0
```

## Falsifier

Any refreshed pin not resolving to the named symbol at HEAD, or the
compliance loader run not reproducing `157 tests, 0 failures`.
