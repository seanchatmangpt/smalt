# BK-107 — WsAmqpRelay combined-tree verification (BK-58 × BK-103b)

**Standing: PASS (relay surface) — `--warnings-as-errors` gate typed UNSUPPORTED (pre-existing, out-of-lane).**
BK-103b's receipt (`bk103b-wsrelay-verify.md`, landed 22:43) closed BK-103 as
premise rot: no relay-side flow-frame defect exists; the credit law lives in
`lib/smalt/messaging/amqp/connection.ex` and is exercised by the relay e2e
court. The relay + test working tree is clean (no dirty edits on the two
relay files at verify time; only workspace/ files were dirty per git status),
so the combined tree = BK-58's landed relay at 73e882e. Context: solo
(MIX_BUILD_ROOT=_build-bk107, repo-pinned Elixir 1.20.4-otp-29 via
~/.asdf shims; homebrew elixir 1.19.5 refuses :smalt).

## (1) Relay court on the combined tree — required gate

```
$ MIX_BUILD_ROOT=_build-bk107 mix test test/internal/ws_amqp_relay_test.exs
Running ExUnit with seed: 778827, max_cases: 32
..
Finished in 2.7 seconds (0.00s async, 2.7s sync)
Result: 2 passed        # exit 0
```

## (2) BK-58 witness legs

The EH publish→consume leg ("EH publish -> consume end-to-end through the
relay (BK-58 witness)", `test/internal/ws_amqp_relay_test.exs:206`) is in
this file and passed in the run above (real Bandit WS server + real EH
listener, payload-integrity asserted, no mocks). BK-82's EH e2e leg is a
workspace engine court, not in this file — out of scope per BK-103b's
audit (line 29-37).

## (3) `mix compile --force --warnings-as-errors`

**Exit 1 — pre-existing, out-of-lane, not session-introduced.** Typed for
owner dispatch, not fixed by this lane:

- Failing apps: `ash_graphlaw` 26.10.8 (lib/ash_graphlaw/model/enums.ex:22),
  `ggen_igniter` 26.10.7 (safe_rename/execute/ggen_toml_io), `smalt` itself
  (generated `lib/smalt/mcp/generated/mcp_descriptor.ex` →
  `Smalt.Mcp.Router.invoke/2` warning surfaced via deps/plug).
- Plain `MIX_BUILD_ROOT=_build-bk107 mix compile --force` → exit 0, 36
  warnings; **zero warnings mention `ws_amqp_relay`** (grep exit 1, no
  matches). The relay file is warning-clean.

## (4) Not fixed by this lane

Nothing red on the relay surface. The census drift BK-103b witnessed
(`bk101_g3_seam_probe_test.exs` / `bk85_seal_invariant_court_test.exs`
unregistered in the tier census) is also out-of-lane, unchanged here.

## Falsifier status

The combined-green falsifier is discharged by the 2/2 exit-0 run on the
combined tree plus the relay-clean compile audit. BK-107 closes PASS on the
relay surface.

## Files

- `lib/smalt/messaging/ws_amqp_relay.ex` — unchanged (73e882e), clean tree
- `test/internal/ws_amqp_relay_test.exs` — unchanged, 2/2 green
- `docs/jira/v26.10.22/receipts/bk103b-wsrelay-verify.md` — upstream receipt

Not committed (per lane contract).
