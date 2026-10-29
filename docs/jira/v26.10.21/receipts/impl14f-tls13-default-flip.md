# IMPL-14F — TLS 1.3 default flip landed (`config :smalt, :tls_versions`)

Context: solo

**Standing:** ALIVE (3-leg court PASS, exit 0; regression file 3/3)

Lane: IMPL-14F finisher, 2026-10-21, repo /Users/sac/smalt,
toolchain asdf elixir 1.20.4-otp-29 / Erlang OTP **29.1.2** (erts-17.1.1),
build root `_build-i14f`.

## Diff (lib/smalt/tls.ex)

Single behavioral line:

```diff
-    versions = Application.get_env(:smalt, :tls_versions, [:"tlsv1.2"])
+    versions = Application rest as [:"tlsv1.3", :"tlsv1.2"])  # see file
```

Exact line in `lib/smalt/tls.ex` (`transport_tls_opts/1`):

```elixir
versions = Application.get_env(:smalt, :tls_versions, [:"tlsv1.3", :"tlsv1.2"])
```

Plus three comment/doc blocks updated (moduledoc, `bandit_opts/2` comment,
`transport_tls_opts/1` comment) naming the evidence pack and the config-revert
escape. No other lib edits. `git diff --stat lib/smalt/tls.ex`:
1 line behavioral, ~20 comment lines.

## Evidence pack (prior lanes, cited not re-run)

- `docs/jira/v26.10.21/receipts/tls13-unpin-trial.md`: 4 wire legs PASS with
  `versions: [:"tlsv1.3", :"tlsv1.2"]` + default ciphers; R90/D52 MLKEM shape
  non-reproducing on this host (openssl `-groups X25519MLKEM768` accepted);
  pin's protective value non-vacuous (control alert 70 reproduced).
- Server-side ML-KEM witness captured by the prior IMPL-14F lane on the
  opt-in 1.3 boot: `selected_group: :x25519mlkem768`.
- Residual stays typed-open: real-Go-client leg (azidentity/azurerm) pending
  via the GOLEG lane — per the trial receipt's own verdict, this residual is
  NOT closed by this flip; it is carried forward, not dismissed.

## Court (tmp/i14f_tls_flip_court.exs)

Real `Smalt.TLS.bandit_opts/2` seam (I14FProbe plug, dev-cert seats,
`openssl s_client -brief` wire probes), ports 39940/39941, `--no-start`
(see note below). Raw output:

```
== Leg 1+2: default config (seam unset) ==
leg1 default tls1_3: rc=0 protocol=TLSv1.3
leg2 default tls1_2: rc=0 protocol=TLSv1.2
== Leg 3: config-revert escape config :smalt, :tls_versions, [:"tlsv1.2"] ==
leg3 escape tls1_3: rc=1 protocol=ALERT-70
leg3 escape tls1_2: rc=0 protocol=TLSv1.2
versions_env_after_escape=[:"tlsv1.2"]
COURT-VERDICT=PASS
```

- Leg 1 (flip): default config negotiates TLSv1.3, exit 0.
- Leg 2 (backward compat): same listener still serves TLSv1.2, exit 0.
- Leg 3 (escape hatch): `Application.put_env(:smalt, :tls_versions, [:"tlsv1.2"])`
  → second listener refuses 1.3 (alert 70, rc=1) and serves 1.2 (rc=0).
  The R90/D52 conservative pin remains one config line away, byte-for-byte.

## Regression

`MIX_ENV=test MIX_BUILD_ROOT=_build-i14f mix test test/integration/h2_reset_rate_parity_test.exs`
→ `3 passed` (KD-157 parity consumers of `bandit_opts/2`, includes real
https Bandit boots).

## Notes (typed)

1. Toolchain: the task premise "OTP 29.1.2 host" holds via asdf
   (`~/.asdf/installs/erlang/29.1.2`); PATH default was 28.3.1, court ran on
   **29.1.2** — the exact toolchain named in the task.
2. One witnessed flake, NOT lane-introduced: one `mix run` (with app start)
   crashed in `Smalt.Application.start/2` — `Supervisor.init_child` got a LIST
   of bandit child specs as a single child (id `{Bandit, #Reference<...>}`),
   ports ephemeral 60xxx. Reproduced shape absent on the two adjacent boots;
   court rerun with `--no-start` is unaffected. Logged here as observed;
   pre-existing supervisor assembly hazard, not the TLS seam.
3. Court script kept at `tmp/i14f_tls_flip_court.exs`, full log
   `tmp/i14f_court_run.log` (scratch, per receipt convention).
4. Build root `_build-i14f` left as lane lease for coordinator cleanup
   (`just lane-clean`).
