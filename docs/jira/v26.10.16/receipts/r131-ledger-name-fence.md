# Receipt — R131 (confidential-ledger non-UTF8 name fence)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/security/confidential_ledger.ex:131` (`ledger_name/1`): adds
  `String.valid?/1` alongside the slash fence — a non-UTF8 name like `a\xFF`
  previously passed the slash-only check, reached `ReceiptSigner.sign`, and
  `Jason.encode!` raised inside the serialized LedgerWriter GenServer after the
  `{:dup, ledger, hash}` counter was incremented — writer death, every retry
  409 LedgerItemAlreadyExists for never-stored content (commit-point law
  violated). Non-binary shapes (42, nil, tuple) are typed-refused at the same
  boundary.

## Verification (2026-10-16, W6 docs lane, unedited output)

Boundary probe (app booted on private ports 19443/19444/18443/19545/35672/35673
to avoid the shared substrate):

```
$ MIX_BUILD_ROOT=_build-w6docs mix run --no-start -e '<port env>' -e '... ConfidentialLedger.append_transaction/2 ...'
r131-non-utf8: {:error, 400, "InvalidLedgerName"}
r131-slash: {:error, 400, "InvalidLedgerName"}
r131-non-binary: {:error, 400, "InvalidLedgerName"}
r131-valid: {:ok,
```

Suite confirmation (ledger + audit planes):

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/security/security_hardening_test.exs test/data_plane/audit_planes_test.exs
145 tests, 0 failures
```

Note: a first probe attempt with the default fixed ports failed
`{:listen_failed, 5672, :eaddrinuse}` / `5673` (shared substrate holds them) —
port names resolved from source (`amqp_port`, `event_hubs_port`) before the
re-run.
