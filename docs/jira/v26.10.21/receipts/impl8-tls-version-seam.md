# IMPL-8 — AR-SEC-01 `config :smalt, :tls_versions` seam + AR-SEC-02 dual-cert court

Context: pair(built on CERTS2 in-flight AR-SEC-02 diff on shared lib/smalt/tls.ex (read from disk, built on, disclosed))

**Standing:** **ALIVE** (court 3/3 legs PASS on the exact committed bytes;
regression tests 5/5 green)

Lane: IMPL-8 writer, 2026-10-21, repo /Users/sac/smalt, build root `_build-impl8`

## Subject

`lib/smalt/tls.ex` — one writer, one file. Landed on top of CERTS2's in-flight
AR-SEC-02 dual-cert diff (read from disk, built on, not duplicated):

1. **Config seam (AR-SEC-01)**: `config :smalt, :tls_versions`
   (default `[:"tlsv1.2"]` — the conservative R90/D52 pin, byte-for-byte the
   old behavior). `:tlsv1.3` opt-in via
   `[:"tlsv1.3", :"tlsv1.2"]`; when 1.3 is enabled the 1.2-only cipher pin is
   dropped in favor of OTP default ciphers — the exact shape the TLS13 trial
   receipt's 4 wire legs ran with
   (docs/jira/v26.10.21/receipts/tls13-unpin-trial.md = evidence pack).
2. **Dual-cert binding (AR-SEC-02, CERTS2's code)**: `certs_keys` when
   `SMALT_TLS_ECDSA=1` / `config :smalt, :tls_certs_keys, true` and a valid
   ECDSA pair exists (`.smalt/tls/ecdsa-{cert,key}.pem`, confirmed on disk:
   EC P-256 leaf, CA-chained, unexpired); RSA-only fallback otherwise.
   I restructured the pin plumbing so both seams compose:
   `transport_tls_opts/1` (versions from seam; pinned 1.2 ciphers augmented
   with ECDSA suites in dual mode) + `single_cert_opts/2` + `ecdsa_ciphers/0`.
3. Moduledoc documents the seam. Also repaired a mangled comment fragment
   ("PKCS#8 from -newkey -nodes.S#8 from -newkey -nodes." duplication).

## Diff

Coordinator tick commit `1570385` swept this lane's tls.ex edits into HEAD
(together with CERTS2's dual-cert and the APIMWIRE charlist SLA unblock);
worktree == HEAD for `lib/smalt/tls.ex` (verified byte-identical via
`git show HEAD:lib/smalt/tls.ex` diff, empty). ~50 net-new lines:
`transport_tls_opts/1`, `single_cert_opts/2`, `ecdsa_ciphers/0`, seam read
`Application.get_env(:smalt, :tls_versions, [:"tlsv1.2"])`, moduledoc.

## Chicago court — 3 legs, all against the real `bandit_opts/2` code path

Harness: `mix run --no-start tmp/impl8_court_boot.exs` — boots ONLY a private
Bandit listener over `Smalt.EgressRouter` via the real `bandit_opts/2` (the
TLS13 trial used its own opts; this court exercises the landed code). Ports
39941-39943 pre-flighted free (lsof), freed after. The smalt application is
not started (live substrate holds 8443/9443/9545; probes are
handshake/cert-level).

**Leg 1 — default boot unchanged (39941)**: BANDIT_OPTS shows
`versions: [:"tlsv1.2"]`, single certfile (no certs_keys).

- `openssl s_client -tls1_2`: `New, TLSv1.2, Cipher is
  ECDHE-RSA-AES256-GCM-SHA384` — PASS
- `openssl s_client -tls1_3`: `tlsv1 alert protocol version ... alert number
  70` — PASS (pin is non-vacuous)

**Leg 2 — opt-in boot negotiates 1.3 (39942)**:
`config :smalt, :tls_versions, [:"tlsv1.3", :"tlsv1.2"]`.

- `-tls1_3`: `New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384` — PASS
- `-tls1_2`: `New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384` — PASS
  (backward compat on the same listener)

**Leg 3 — dual-cert serves EC to ECDSA-preferring, RSA to legacy (39943)**:
`SMALT_TLS_ECDSA=1` (pair from `.smalt/tls/ecdsa-*`).

- ECDSA-preferring (default OpenSSL client, both suites offered): server picks
  `ECDHE-ECDSA-AES256-GCM-SHA384` and serves the `id-ecPublicKey` leaf;
  chain verifies `Verify return code: 0 (ok)` against `.smalt/tls/ca-cert.pem`
  — PASS
- legacy RSA-only (`-sigalgs rsa_pss_rsae_sha256:rsa_pkcs1_sha256`): server
  serves `ECDHE-RSA-AES256-GCM-SHA384` + `rsaEncryption` leaf — PASS

## Typed residual (probe limitation, pre-existing)

`openssl s_client -sigalgs <single-family>` (e.g. `ECDSA+SHA256` alone) fails
with server alert 71 (`:no_suitable_ciphers`) against the SHIPPED single-RSA
listener too (control reproduced on 39941 with `RSA+SHA256`). Sigalg-only
restriction is broken against this OTP 28.3.1 server generally — not
introduced by this diff; the ECDSA/RSA selection is demonstrated via the
client's ciphersuite offer (the real-world mechanism) instead. A real
Go/azidentity client leg re-run remains the TLS13-trial residual for any
default flip (unchanged from that receipt).

## Regression

`mix test test/integration/h2_reset_rate_parity_test.exs
test/integration/tls_blob_dispatch_test.exs` (MIX_BUILD_ROOT=_build-impl8):
**5 tests, 0 failures**.

## Compile-freeze disclosures

- blob_storage.ex / file_share.ex were mid-broken by the OTP-29 lane's
  `is_integer/3` guard sweep while this lane booted; the owning lane landed
  its own `defguardp` fixes between this lane's retries (IMPL-4's fix is
  marked in-file). This lane applied no edits to those files.
- Session-introduced artifacts: `tmp/impl8_court_boot.exs`,
  `tmp/impl8_boot_leg.sh`, `tmp/impl8_{default,tls13,dual}_boot.log` (lane
  artifacts, gitignored).

## Falsifier status

- Default-boot-unchanged: held (leg 1).
- Opt-in 1.3: held on openssl legs; real-Go-client leg still outstanding
  before any default flip (inherited residual).
- Dual-cert selection: held both directions on ciphersuite-driven selection.

Machine context: local macOS (Darwin 25.2.0), OTP 28.3.1, OpenSSL 4.0.3,
Bandit 1.13.1. (No bench throughput numbers — this is a protocol court, not a
perf lane; `just bench-machine` not applicable.)
