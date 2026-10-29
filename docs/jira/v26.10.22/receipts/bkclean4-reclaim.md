# BK-CLEAN4 — lane build-root reclaim (v26.10.22)

Standing: ALIVE · Context: solo · 2026-10-22 09:05

## Census (real, at 09:00–09:04)

Started 25 roots / 6.00 GiB. The tree churned under concurrent lanes during the
census itself — a second listing minutes later showed 13 roots; final listing
(09:05) shows 11. All numbers below are the actual command outputs.

## Reclaimed (receipt-on-disk cross-check)

| root | size | receipt |
|---|---|---|
| `_build-bkampv` | 713.9 MiB (730,660 KiB) | `receipts/bkampv-parse-verify.md` |
| `_build-bkgws7v` | 713.6 MiB (730,688 KiB) | `receipts/bkgws7v-gate5.md` (also committed, de1aec1a~) |
| `_build-bkprofv` | 713.5 MiB (730,668 KiB) | `receipts/bkprofv-profile-verify.md` |

`du -sk` exact: 2,192,016 KiB = **2.09 GiB** reclaimed from build roots.
Plus 0.63 MiB `/tmp` landed-probe scratch (`expl10r_court_*.dets`,
`smalt-cli-sub-bkcliv-*`, `smalt-cli-sub-expl12*` logs). **Total: 2.09 GiB.**

Embedded before/after (`du -sk _build-* | awk` sum):
- BEFORE: **6.18 GiB** (25 roots at 09:00)
- AFTER: **4.09 GiB** (22 roots at 09:04) — but concurrent lanes minted new
  roots mid-run; a re-measure read 4.39 GiB and 11 roots at 09:05. Reclaimed
  amount (2.09 GiB) is the exact deleted set, the trustworthy number; the
  after-total is noisy by live-lane minting.

## Kept (live / pending)

- Hot lanes (mtime <20 min at 09:04): `_build-bkb4rv`, `_build-bketsf`,
  `_build-bkexw2`, `_build-bkfondv2`, `_build-bkgoseq`, `_build-bkgwsq` (17 min),
  `_build-bknsp`, `_build-bkpatw`, `_build-bksqld2x`, `_build-bkw32`
- `_build-bkseal6` (38 min): no `bkseal6*` receipt on disk — in-flight
  quiet-x2 lane, kept pending its receipt.
- Live named set (bkwit4, bkmon5/6, bkdupid, bkbquiet, bkgwsskep2, bkb4rc,
  bkb7cr, bkf1a, bkfondw) had already been reclaimed by prior clean lanes;
  only `bkgoseq` still existed and is on the live list anyway.

## /tmp

Kept: `/tmp/smalt-substrate-state` (82 MiB, live substrate), substrate locks,
hot-lane logs (bkpatw/bkgoseq/bkseal6/bkexw2/bkfondv2). Deleted only
landed-probe scratch above.
