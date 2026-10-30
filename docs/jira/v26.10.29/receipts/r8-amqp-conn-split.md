# r8 — amqp connection split (T08, lane L08)

- window: v26.10.29 · date: 2026-10-29 · subject: smalt canonical checkout,
  lane L08 build root `_build-l08`
- standing: **PARTIAL_ALIVE** — split landed; wire tier byte-identical to a
  control arm built from the same tree with the monolith restored
  (298/376 vs 298/376, failure sets equal location-for-location); amqp10
  integration courts 27/27 green post-split; whole-tier byte-green NOT
  claimed — 78 wave-level failures present IDENTICALLY in both arms.

## Extraction

`lib/smalt/messaging/amqp/connection.ex` (3,520 lines) → root (~660 lines)
plus four phase modules under `lib/smalt/messaging/amqp/connection/`:

| module | surface |
|---|---|
| `Handshake` | protocol-header peel (`handle_header/1`), SASL
  (`handle_sasl/2`, ANONYMOUS-only), `open` negotiation (`handle_open/2`),
  `configured_max_frame_size/0` |
| `Session` | `begin`/`flow`/`end`/`close` handlers, per-channel session
  map (`get_session`/`put_session`), outbound `send_flow/3`,
  `@max_link_credit` clamp |
| `Link` | `handle_attach/3` routing (queue/`$cbs`/`$management`/EH),
  `handle_detach/3`, credit bookkeeping (`add_credit`/`set_credit`/
  `bump_credit`/`put_link`/`link_by_handle`/`update_links`),
  EH selector-filter + epoch registry (`eh_*`), partition identity
  (`eh_partition`, `eh_partition_scope`, `eh_storage_partition`), address
  normalization (`address_of`, `bare_entity`, `route`, `authorized?`) |
| `Delivery` | transfer ingestion (`handle_transfer`,
  `ingest_message`, batching), `$cbs`/`$management` RPC (`handle_cbs`,
  `handle_management`, `ensure_cbs_router`, `find_reply_link`),
  credit-driven delivery (`deliver_available`, `deliver_to_link`,
  EH aggregate/partition paths), disposition settlement
  (`handle_disposition`, `settle/3`, KD-77/KD-134 state), outbound
  transfers (`send_message`, chunking) |

Connection root keeps: crash-only GenServer (temporary restart,
trap through supervision; terminate releases session locks), input pump
(`next_input`/`need_more`/`pump_drain`/`rest_after`), redelivery sweep
(KD-127), `send_frame`/`close_with_error`/`error_close`/`plain` shared
wire helpers, and performative → phase-module state routing.

All bodies moved verbatim; visibility widened only where a moved function
is called cross-module (`def send_frame`, `def error_close`,
`def close_with_error`, `def plain` on the root; `def` on Session/Link/
Delivery/Handshake entry points and shared state helpers). Wire behavior
carried unchanged: SASL ANONYMOUS advertised set, sasl-outcome 0x44 code
semantics, attach top-level <=14 with locale fields omitted (source=8 /
target=7 composite arity tripwires), .NET-GUID lock-token reorder
(LockManager.token_to_wire), EH fixed partitions ["0","1"].

## Gate (typed substitution, disclosed)

Ticket gate `MIX_BUILD_ROOT=_build-l08 mix test --include amqp_wire`
selects zero tagged tests inside `test/**` (the tagged `:amqp_wire`
suite lives at `docs/jira/v26.10.18/burn/test/amqp/`), so it would run
the whole offline suite — r0-baseline already records 143 host-wide
pre-existing failures. Substituted tier: the tagged wire suite itself,
run as an A/B pair:

- post-split (main tree):
  `MIX_BUILD_ROOT=_build-l08 mix test docs/jira/v26.10.18/burn/test/amqp --include amqp_wire`
- control (scratch `/tmp/l08-base`, guard-sanctioned `git archive` HEAD
  + current lane files overlaid, connection split reverted to the
  3,520-line monolith via `git show HEAD:...`), build root seeded from
  `_build-l08`

First arm pair (helpers unresolved — see court note): **209/376 passed,
167 failed on BOTH sides**; failure locations: 254/254 matched
(file:line, identical multiplicities), 0 post-only, 0 ctl-only.

Court note (harness artifact, applies to both arms): the burn suite's
support modules (`SmaltTest.Env`/`Lifecycle`) live outside the root
project's `elixirc_paths`, so env-dependent tests bail at setup with
`put_restored/1 is undefined`. After compiling the burn support beams
into both build roots, the strengthened pair:

- post-split: **298/376 passed, 78 failed**
- control: **298/376 passed, 78 failed**
- failure locations: **172/172 matched** (file:line, identical
  multiplicities: `COUNTDIFF` lines = 0, post-only = 0, ctl-only = 0)

```
$ MIX_BUILD_ROOT=_build-l08 mix test docs/jira/v26.10.18/burn/test/amqp --include amqp_wire
Finished in 68.5 seconds (11.4s async, 57.1s sync)
Result: 298/376 passed
Failed: 78 tests

$ cd /tmp/l08-base && MIX_BUILD_ROOT=_build-l08-base mix test burntest/amqp --include amqp_wire
Result: 298/376 passed
Failed: 78 tests
```

Per-file (failures, identical both arms): queue_store 67, connection 26
locations, flow_credit 20, management_rpc 19, cbs_router 14, fuzz 9,
selector_epoch 9, atom_bridge 4, frame_codec 2, event_hubs 2,
delivery_encoder 2; all-pass files: broker_facade, lock_manager,
primitive_codec, pyamqp_parity, r129_session_gate, sas_verifier,
sweeper. The remaining 78 are wave-level (other lanes' concurrent
decompositions: frame_codec/, management_rpc/, cosmos/, key_vault/
splits in flight, plus compile-freeze tears in egress_router, blob
website, oidc_authorize, arm_gateway/router) — present in the control
arm, therefore not attributable to this split.

`test/integration` AMQP courts post-split (main tree):

```
$ MIX_BUILD_ROOT=_build-l08 mix test test/integration/amqp10_crash_only_court_test.exs \
    test/integration/amqp10_adversary_court_test.exs \
    test/integration/amqp10_skeptic_court_test.exs \
    test/integration/amqp_kd131_133_triage_test.exs
Result: 27 passed
```

(27/27, zero failures, real sockets.) A fourth tier
(amqp10_bk116_skeptic, amqp10_ledger_owner_court, amqp_websocket_bridge)
was attempted twice and BLOCKED both times by another lane's torn
`lib/smalt/arm_gateway/router.ex` — typed disclosure, not run.

## Compile

- five lane files compile with **zero warnings**
  (`touch` + `mix compile` filtered on `messaging/amqp/connection` → no
  output).
- scratch standalone check: `elixirc` of the five files → 5 beams, no
  real errors.

## Compile-freeze unblock (disclosed, both-receipt rule)

- `lib/smalt/policy/eval.ex`: another lane's torn write left a duplicated
  trailing `end` (syntax error) that froze every lane's compile; removed
  the one duplicate line. Not this lane's file; disclosed here for the
  owning lane to mirror in its receipt.
- Other tears (cosmos/auth.ex, iac_export/terraform.ex, cosmos/
  databases.ex, mcp/tool/cosmos.ex, key_vault certs/keys, egress_router,
  blob/website.ex, identity/oidc_authorize.ex, arm_gateway/router.ex)
  self-repaired by their owning lanes mid-window; no action taken.

## Pinion receipt

Handshake module docstring now carries the pinion list verbatim (SASL
ANONYMOUS advertised set; sasl-outcome 0x44 code semantics; attach
top-level <=14, locale fields omitted, source=8/target=7 composite arity
tripwires; .NET-GUID lock-token byte reorder; EH fixed partitions
["0","1"]). No pinion value was edited — all moved code is verbatim;
visibility-only changes.

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
MIX_BUILD_ROOT=_build-l08 mix test docs/jira/v26.10.18/burn/test/amqp --include amqp_wire
# control arm: /tmp/l08-base (HEAD archive + current lane overlay, monolith restored)
```

- falsifier: any failure location present in exactly one arm → would
  have been a split regression; observed 0 (both pairs).
- falsifier (pinions): any diff in the pinned bytes → would show as a
  frame_codec/attach-arity/SASL wire test diff between arms; observed 0
  attach-arity / SASL / lock-token diffs (pyamqp_parity, sas_verifier,
  r129_session_gate all-pass in both arms).
- residuals: 78 wave-level failures (identical both arms) — owned by the
  decomposition wave, not this lane.
