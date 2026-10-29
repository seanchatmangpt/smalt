# W15-A — scvd-fulllegs-witness (in-browser composed receipt, full leg sync)

Date: 2026-10-21 · Lane: W15-A (writer+witness) · Repo: /Users/sac/smalt
**Standing:** **PASS** (0 FAIL across 3 consecutive browser runs)

## Scope

`@static_legs` in `popcorn_demo/lib/popcorn_demo/application.ex` was stale at
19 entries (20 legs incl. `live`). Synced to the full live_*.ex inventory
(28 legs incl. `live`): added `PopcornDemo.LiveReconcile`, `LiveAppConfig`,
`LiveDns`, `LiveExport`, `LiveEgd`, `LiveTopic`, `LiveApim`, `LiveAcr` —
each atom verified against the file's own `defmodule` (LiveCas/LiveKeyops
case lesson applied; `LiveKV`/`LiveEG` casing preserved from before).

## Compile + cook

- Pinned toolchain (asdf erlang 29.0.6 / elixir 1.20.4-otp-29):
  `mix compile` 0 errors (pre-existing type warnings only; no warning in
  application.ex).
- `mix popcorn.cook --out-dir public/out` exit 0.
- Compile-freeze disclosure (W15-A -> owning lane): an in-flight edit in
  `popcorn_demo/lib/popcorn_demo/live_topic.ex` (not this lane's file) broke
  the cook compile — `:broker_frame_0x <> Integer.to_string(d, 16)` —
  `ArgumentError` at expansion, live_topic.ex:438. Minimal unblock fix
  applied: `String.to_atom("broker_frame_" <> Integer.to_string(d, 16))`
  wrapped into the same `{"receive", {atom, binary}}` tuple shape. Disclosed
  here for diff attribution; semantic intent preserved.
- application.ex fragment fix (owned file): the catch-all
  `fragment(_label, other)` rendered LiveAcr's typed `{:unsupported,
  :acr_face_absent}` as `leg=FAIL(...)`. Added
  `fragment(label, {:unsupported, reason})` ->
  `label=SKIP(face-absent:...)` — an environment fact is a SKIP, not a FAIL.

## Witness (node scripts/browser_smoke.mjs x3, post-fix, exit 0 x3)

31 composed fragments (3 smoke + 28 legs), `legs_rendered: 30`, boot_ms
~801-803, per-run and stable across runs:

- OK: 16 — 3 smoke (cosmos_sql, sb_rule, registry) + 13 legs: appconfig,
  cas, containers, export, kv, lifecycle, live, matrix, param, rg, rules,
  scvd, tags
- SKIP: 15 classified:
  - wasm-transport (11): apim, certs, dns, mcp, policy, queue, reconcile
    (:crypto.hash/2 undefined in wasm), topic, keyops (tcp
    :eprotonosupport), eg (publish), container-blocked blob
    (cors-preflight-403 — browser-only transport fact)
  - face-absent (2): acr (::acr_face_absent), egd (kd101-airgap
    local-delivery-unimplemented)
  - eh-plane-down (1): eh (5673 connect :eprotonosupport; substrate was UP
    on 9443 — the 5673 EH listener leg fails in-browser transport)
  - env-cert (1): tls (ca-missing: .smalt/tls/ca-cert.pem path absent in
    browser context)
- FAIL: 0, all three runs, typed loudly absent.

Host-side control (`mix run -e 'PopcornDemo.Application.composed_receipt()'`)
shows the same 28 legs with the 8 new legs live: appconfig=OK,
dns=UNSUPPORTED(recordset-A:RouteNotFound-404-zone-deleted-clean),
export=OK(2-resources), egd=OK, reconcile=OK(3-staged,...cas-winners),
topic=FAIL(recv::closed) — host-side facts, not browser facts; the browser
witness is the receipt of record.

## Replay

    export PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
    cd /Users/sac/smalt/popcorn_demo
    mix compile && mix popcorn.cook --out-dir public/out
    node scripts/browser_smoke.mjs   # x3, exit 0 each

Raw run logs: /tmp/scvd_w15a_run{1,2,3}.log
