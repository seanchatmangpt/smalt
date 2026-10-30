# multi-agent-compile-freeze-economics

What 17 concurrent lanes on one canonical checkout actually cost in
compile freezes this session, which mechanisms absorbed it, and the
escalation protocol that resolved the one freeze nothing else absorbed.

## The observed costs (receipt-grounded)

- GGEN-IDP's window (r12 §4): five distinct freezes in one ledger,
  22:00-23:01 PDT — policy/eval.ex, cosmos/auth.ex (truncated mid-write),
  mcp/router.ex + mcp/tool/cosmos.ex, purview_atlas/glossary.ex,
  oidc_authorize.ex (a T05 dev loop iterating in place). Every one was
  resolved by its owner; no SLA unblock was applied by that lane.
- GGEN-CACHE (r11): one other lane's file (data_plane/key_vault/hsm.ex,
  new, not in HEAD) was compile-broken for 45+ consecutive
  `mix compile` attempts across ~30 min with three distinct syntax
  defects (r11 names line 38 unclosed map, line 44 missing brace, line 53
  stray text). r11's gate stayed BLOCKED the whole window.
- L15 (r10d): two bounded polls between compile attempts used sleep
  spacing (60-100 s) while waiting on other lanes' compile freezes —
  disclosed in r10d as a violation of the letter of no-sleep polling;
  the polls' observable was the compile exit code, and no pass/fail
  claim rode on the spacing.

## Why per-lane MIX_BUILD_ROOT works

Every receipt's commands pin a private build root (`_build-t02`,
`_build-gc1`, `_build-gi1`). Compilation writes then stay lane-local, so
a torn file in `lib/` is the only shared-freeze channel left — build-root
collisions are designed out.

## Why torn shared files cost every lane

`mix compile` reads all of `lib/`. One lane's in-flight file fails every
other lane's compile, so the freeze multiplies by lane count. r11's
45-attempt stretch is the multiplier made visible: one file, one owner,
~30 minutes of every polling lane's gate time.

## The economics

A freeze is a tax paid in gate latency by all lanes for the wall-clock
the owner needs. The ledger shows the tax is usually small (r12: owner
fixes in 5-7 minutes each) and occasionally dominated by one long tail
(r11: hsm.ex). The design question is not "how to prevent freezes" —
concurrent lanes editing one tree will tear files — but "who pays, and
when does the tax become a subsidy the owner no longer controls".

## The SLA escalation protocol (the answer the wave converged on)

Per the compile-freeze SLA (r11 §task-3 applies it verbatim):

1. Owner fixes or reverts within ~10 minutes of the freeze.
2. Past that, any lane may apply a minimal disclosed unblock — but only
   if the repair is lexical with provable semantics.
3. The bar is load-bearing. r11 REFUSED to repair hsm.ex even at 45+
   attempts, because the garble sat inside MHSM KW-algorithm clauses and a
   compiles-clean repair would silently change which algorithms succeed
   (a capability regression disguised as an unblock). None of the breaks
   were minimal lexical repairs, so none were touched.
4. Disclose in both lanes' receipts any unblock applied (r3's leg-2
   disclosure: the Bandit opts one-hop fix in saml_idp.ex, bounded owner
   window first, re-verify on disk before citing).
5. The gate records BLOCKED with the failing file named for re-run —
   never a skip, never a faked pass (r11 names the four test files for
   re-run once hsm.ex lands).

## The polling discipline underneath

Waits rode bounded polls on real observables (compile exit, listener
socket) — r12's ledger note: "every one of my mix steps ran inside a
bounded poll on the real observable (compile/exit), no Process.sleep".
One deviation is on the record: r10d's sleep-spaced polls, disclosed
above. The doctrine the wave enforced: the observable is the compile/test
exit; spacing between attempts must be a bounded poll, and a poll times
out and escalates where a sleep just waits.

## Related

- [adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)
- [vacuous-courts-and-real-clients](vacuous-courts-and-real-clients.md)
