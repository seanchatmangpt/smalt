# TS Ledger Probe — Confidential Ledger REST surface (lane 329)

Standing: **ALIVE** — 7/7 PASS, exit 0, on a lane-private substrate
(ports 39317 arm / 39318 data / 39319 amqp, `MIX_BUILD_ROOT=_build-lane329`,
anonymous auth, lock fd closed on boot).

## Subject

- Probe: `/Users/sac/smalt/test/sdk-full/ledger.probe.mjs`
- Surface: `POST/GET /app/transactions` (data plane) served by
  `lib/smalt/egress_router.ex` -> `lib/smalt/security/confidential_ledger.ex`
  -> `lib/smalt/security/ledger_writer.ex`
- SDK: `@azure/azure-confidentialledger` is not in `test/sdk-full/node_modules`;
  probe rides plain REST (the same wire the SDK would drive).

## Command

```bash
cd /Users/sac/smalt/test/sdk-full && node ledger.probe.mjs; echo "exit=$?"
```

## Output (receipted run, 2026-10-16)

```
[PASS] append.lazy-create — status 201, tx 5.1, subLedgerId=default_ledger
[PASS] read.by-tx-id — tx 5.1 envelope complete (data_hash/prev_hash/merkle_root/signature/contents)
[PASS] receipt.chain-hash — merkle_root=5784ac3a3a7c425e… == sha256(prev_hash||data_hash)
[PASS] append.chain-link — tx 6.1: prev_hash == tx1.merkle_root; chain extends
[PASS] read.latest — latest == tx 6.1
[PASS] read.list-order — list has 6 receipt(s), tx1 before tx2
[PASS] read.unknown-tx — 404 TransactionNotFound envelope

ledger probe: 7/7 PASS
exit=0
```

## Checks

| check | assert |
|---|---|
| append.lazy-create | first-ever append (no create route exists on the surface) returns 201 with `transactionId` — KD-42 lazy-create default evidence |
| read.by-tx-id | GET by tx id round-trips the full receipt envelope (`data_hash`/`prev_hash`/`merkle_root`/`signature`/`contents`) |
| receipt.chain-hash | `merkle_root == sha256(prev_hash <> data_hash)` |
| append.chain-link | second append's `prev_hash` equals first receipt's `merkle_root` |
| read.latest | `GET /latest` matches the newest receipt |
| read.list-order | list contains both receipts in monotonic tx-id order |
| read.unknown-tx | unknown tx id -> typed 404 `TransactionNotFound` envelope |

## KD-42 evidence (MATCHED re-grade)

The probe's very first operation is an append to a never-created subledger.
It succeeds with 201 (`tx 5.1`, `subLedgerId=default_ledger`) — no creation
call precedes it and no creation route exists on the surface. This is the
observed behavior matching the re-grade target: smalt's lazy-create default
(divergence from Azure's 404-on-uncreated-ledger append) is exercised on the
real wire, not inferred from source.

## Exit contract

0 pass / 1 fail / 2 substrate down (preflight TCP check, loud) / 3 harness error.
