# smalt-04 fnox io hosting deploy witness

Standing: UNVERIFIED

## Problem

Hosting for smalt.fnox.io is authored, not deployed. The fnox repo guide
`/Users/sac/fnox/docs/setup/fnox-io-domain.md` maps `smalt.fnox.io` to an A record, but
fnox.io registration is pending ACTIVE, so no DNS answer or health probe has been
observed. smalt has no hosting receipt. `/Users/sac/smalt/lib/smalt/health_plug.ex` is the probe
target.

## Acceptance

- After registration is ACTIVE: `dig +short smalt.fnox.io` returns an A record and
  `curl -fsS https://smalt.fnox.io/health` returns 200.
- Record both outputs in `/Users/sac/smalt/docs/verification/smalt-hosting-witness.md` with date.
- Until ACTIVE, the file states BLOCKED with the registration status observed.

## Falsifier

Point the probe at a hostname with no record; the witness script must exit non-zero
and must not write PASS.

## Owned files

/Users/sac/smalt/docs/verification/smalt-hosting-witness.md, /Users/sac/smalt/docs/DEV_ENV.md
(hosting section only)

## Depends-on

fnox.io registration ACTIVE (fnox repo /Users/sac/smalt/docs/setup/fnox-io-domain.md)

## Size

S

## References (path : LOC)

- /Users/sac/fnox/docs/setup/fnox-io-domain.md : 128 lines
- /Users/sac/smalt/lib/smalt/health_plug.ex : 101 lines
- /Users/sac/smalt/docs/DEV_ENV.md : 60 lines
- /Users/sac/smalt/docs/verification/smalt-hosting-witness.md : NEW (0 lines, to be created; est.
  LOC: 25; dig + curl outputs, date, BLOCKED/PASS line)

## Result

Standing: BLOCKED (observed: dig returns 136.81.33.94; curl /health exit 35, no 200; registration status unobserved)
Files: /Users/sac/smalt/docs/verification/smalt-hosting-witness.md (~38 LOC, new), /Users/sac/smalt/docs/DEV_ENV.md (+4, hosting section)
Acceptance: `dig +short smalt.fnox.io && curl -fsS https://smalt.fnox.io/health`
