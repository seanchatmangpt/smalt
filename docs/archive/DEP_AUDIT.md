# Dependency Security/Maintenance Audit — v26.10.14

As-of date: 2026-10-14. Scope: direct deps in `mix.exs` (`bandit ~> 1.6`,
`plug ~> 1.16`, `cors_plug ~> 3.0`, `jason ~> 1.4`, `joken ~> 2.6`, plus
optional/dev `ash`, `ash_graphlaw` (path, dev), `ggen_igniter` (path, dev)) as
resolved in `mix.lock`. The `mix deps.audit` task is not available (no
`mix_audit` dep; none added per scope). Advisory surface captured live from
`MIX_ENV=prod mix deps.get` (verbatim, 2026-10-14; grep -c VULNERABLE = 1, so
this is the only flagged package):

```text
  bandit 1.12.5 VULNERABLE!
    EEF-CVE-2026-105659 (HIGH)
    aka: CVE-2026-105659, GHSA-69m6-wcv4-rwcf
    HTTP/2 blocked-send deadlines reset on every WINDOW_UPDATE, letting a trickle pin stream processes indefinitely in Bandit
    https://osv.dev/vulnerability/EEF-CVE-2026-105659
```

## Direct deps

| dep | pinned (mix.lock) | latest on hex (2026-10-14) | advisories | verdict |
|---|---|---|---|---|
| bandit | 1.12.5 | 1.12.5 | EEF-CVE-2026-105659 / GHSA-69m6-wcv4-rwcf — HIGH, HTTP/2 WINDOW_UPDATE stream-pin DoS | **SHIP (accepted)** — 1.12.5 is the latest hex release; no patched version exists yet. Re-audit when one lands. |
| plug | 1.20.3 | 1.20.3 | none known | SHIP |
| cors_plug | 3.0.3 | 3.0.3 | none known | SHIP |
| jason | 1.4.5 | 1.4.5 (1.5.0-alpha.2 exists as pre-release only) | none known | SHIP |
| joken | 2.7.0 | 2.7.0 | none against 2.7.0; 2.7.0 is itself the fix release for CVE-2023-50966 (via jose) | SHIP |

## Exposure note (stated honestly)

Smalt is documented as a loopback-only local substrate for offline testing.
The bandit advisory is a remote-DoS class issue against the HTTP/2 listener; on
a loopback bind it requires a local process to exploit. However,
"loopback-only" is a deployment-time property, not one enforced in repo code —
the listener bind address is runtime configuration. Any non-loopback bind turns
this into a directly exploitable HIGH remote DoS; such deployments should treat
this as UPGRADE-BEFORE-SHIP once a patched bandit release is published.

## Fix path

When a bandit release newer than 1.12.5 addressing EEF-CVE-2026-105659 /
GHSA-69m6-wcv4-rwcf lands, `mix deps.update bandit` resolves to it with no
`mix.exs` change (constraint `~> 1.6` already permits any 1.x).

## erl_crash.dump hygiene

- `erl_crash.dump` (7,564,118 bytes, generated 2026-10-14 17:13) exists at the
  repo root — real artifact from a VM crash during today's session.
- `.gitignore` contains the line `erl_crash.dump` (unanchored, so it matches at
  any depth — also covers dumps in subdirectories). Coverage: adequate.
- Residual risk: none for VCS hygiene. Disk hygiene only — 7.2 MB dump at repo
  root; safe to delete once any crash investigation that needs it is done.

## Optional/dev-only and transitive deps (not release-gating)

- `ash 3.36.0` (optional) and `ash_graphlaw` / `ggen_igniter` (path deps, dev
  only) are excluded from the release closure (`mix release` omits dev-only
  deps); their advisory status does not gate SHIP for the smalt artifact.
- `jose 1.11.12` (transitive via joken) is the CVE-2023-50966-patched version. SHIP.
- `wasmex 0.15.1` (transitive) is native Rust via rustler;
  `rustler_precompiled 0.10.0` supplies checksummed precompiled artifacts.
  Acceptable supply-chain posture.

## Verdict summary

- bandit 1.12.5 — SHIP (accepted risk; re-audit when a patched release lands)
- plug 1.20.3 — SHIP
- cors_plug 3.0.3 — SHIP
- jason 1.4.5 — SHIP
- joken 2.7.0 (+ jose 1.11.12) — SHIP
