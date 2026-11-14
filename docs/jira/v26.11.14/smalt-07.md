# smalt-07 azure serverless row and live test directory

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docs/azure-parity/AZ2.md` caveats: no Functions row exists in
`/Users/sac/smalt/docs/WIRE_PARITY.md`,
so serverless standing is unverified; test pins are retired paths (/Users/sac/smalt/test/compliance,
/Users/sac/smalt/test/amqp, /Users/sac/smalt/test/wire) and there is no
`/Users/sac/smalt/test/azure/` directory. `/Users/sac/smalt/lib/smalt/azure/` holds
only kv_certificates.ex and log_analytics.ex; AZ2-matrix.json marks 0 GAP cells by file
presence only, which carries no pass evidence.

## Acceptance

`grep -n "Functions" /Users/sac/smalt/docs/WIRE_PARITY.md` returns a row with ALIVE/PARTIAL/typed
UNSUPPORTED, and `/Users/sac/smalt/docs/azure-parity/AZ2-matrix.json` carries a pass-state field
populated from a real `mix test` run.

## Falsifier

Remove the pin file named by the Functions row; a row-to-file check must fail.

## Owned files

/Users/sac/smalt/docs/WIRE_PARITY.md, /Users/sac/smalt/docs/azure-parity/AZ2.md,
/Users/sac/smalt/docs/azure-parity/AZ2-matrix.json

## Depends-on

smalt-06 (shared receipt format)

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docs/azure-parity/AZ2.md : 17 lines
- /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json : 9 lines
- /Users/sac/smalt/docs/WIRE_PARITY.md : 296 lines
- /Users/sac/smalt/lib/smalt/azure/ : 2 files, 170 lines total
- /Users/sac/smalt/lib/smalt/azure/kv_certificates.ex : 131 lines
- /Users/sac/smalt/lib/smalt/azure/log_analytics.ex : 39 lines
- /Users/sac/smalt/docs/aws-parity/AS1-aws-census.md : 17 lines (shared receipt format via smalt-06)
- /Users/sac/smalt/test/azure/ : NEW (0 lines, to be created; est. LOC: 0, ticket adds no dir; live
  pins sit in test/integration and test/courts)

## Result

Standing: PARTIAL (UNVERIFIED execution; Functions row already at WIRE_PARITY.md:175; no run by this lane)
Files: /Users/sac/smalt/docs/azure-parity/AZ2-matrix.json (+pass_state=UNVERIFIED x7), /Users/sac/smalt/docs/azure-parity/AZ2.md (+6 LOC). WIRE_PARITY.md unchanged.
Acceptance: grep -n Functions /Users/sac/smalt/docs/WIRE_PARITY.md; run mix test on test/integration/functions_test.exs and container_groups_test.exs, then set serverless pass_state.
