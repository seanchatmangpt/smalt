# KD: composed SMOKE_RECEIPT mid-line truncation — diagnosis + fix

**Standing:** ALIVE (root cause identified from real reproduction data; fix landed, verified in-browser 3/3)

## Defect

Composed in-browser SMOKE_RECEIPT intermittently read as truncated mid-line
(witnessed: 483 chars ending at `eg=SKIP`; other runs full ~1100+ chars).

## Reproduction (headless, pre-fix)

`node scripts/browser_smoke.mjs` x5 (popcorn_demo/, cooked bundle @ pre-fix):

- 5/5 runs composed a FULL receipt — no in-browser write failure, no wasm
  string-size limit hit (suspects b and c refuted by execution).
- The receipt BINARY contained raw NEWLINES (suspect (a) confirmed):

```
keyops=SKIP(wasm-transport:no with clause matching:

{:error, {:tcp_connect, :eprotonosupport}}
); kv=FAIL(challenge:...
```

- The "truncation" is a reader-side artifact: any line-oriented consumer
  (console.log first-line, downstream grep) reads line 1 only. Which leg sits
  at the cut point varies with WHICH leg embeds a newline in its
  Exception.message/inspect text — intermittent `eg=SKIP`/`keyops` cuts, same
  mechanism.

## Root cause

`PopcornDemo.Application` fragments embed leg failure text verbatim:
`slice/1` (80-char cap) preserves `\n`; `inspect` of connect errors wraps;
`Exception.message` multi-lines. The composed `Enum.join("; ")` produced a
multi-line receipt. No early-report path exists (single final write; the
smoke-line write in `Smoke.run/0` precedes the composed write sequentially,
single writer, and browser_smoke polls until `live=` — not the defect).

## Fix (single surgical change)

popcorn_demo/lib/popcorn_demo/application.ex (sha256[:16] a0295c6224a2a5dc):
`composed_receipt/0` now maps every fragment through
`sanitize_fragment/1` — control chars (`\x00-\x1f\x7f`) collapsed to spaces,
whitespace runs squeezed, then `PopcornDemo.Redact.fragment/1` (JWT redaction
+ 120-char cap, the receipt-hygiene law already enforced for the catch-all).
Cooked into the browser bundle (`mix popcorn.cook --out-dir public/out`,
pinned toolchain erlang 29.0.6 / elixir 1.20.4-otp-29).

## Verification

- Host: `mix test` (isolated `_build-w13q`): 90/91 passed. The 1 failure is
  PRE-EXISTING drift, not session-introduced: `test/live_kv_test.exs:57`
  parses `kv=OK(popcorn-secret-<n>-bytes-lifecycle)` but
  `lib/popcorn_demo/live_kv.ex:63` now emits
  `kv=OK(#{run_name()}:#{n}-bytes-lifecycle)` — lib format gained `run_name`,
  test not updated. Touched by no file in this receipt.
- In-browser post-fix `node scripts/browser_smoke.mjs` x3: 3/3 receipts
  single-line (0 newlines, 0 CR), 1181 chars, end at
  `tls=SKIP(ca-missing:...)`; `live=OK` present; substrate UP (9443/9444/5672).
- Post-fix exit=1 is solely the PRE-EXISTING
  `kv=FAIL(challenge:{:challenge_tcp_connect, :eprotonosupport})` leg
  (present in pre-fix runs too — substrate kv challenge over wasm transport),
  not session-introduced.

## Scope / residues

- Not changed: compose Task concurrency, await_leg yield/shutdown path
  (verified no early-report path), Redact, live_kv format, live_kv_test.
- Residue 1 (open, not mine): live_kv_test.exs:57 vs live_kv.ex:63 format drift.
- Residue 2 (cosmetic): `eh=SKIP(eh-plane-down(...); run 9>&- just
  substrate-up)` embeds "; " inside a fragment, corrupting the "; " join
  grammar for strict parsers. Sanitizer does not fix this (it is not a
  control-char issue); a fragment-level separator-free law would.
