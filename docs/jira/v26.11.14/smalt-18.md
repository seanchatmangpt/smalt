# smalt-18 container image build receipt refresh

Standing: UNVERIFIED

## Problem

`/Users/sac/smalt/docker/BUILD_RECEIPT.md` records the image build as of 2026-10-18 (AZB-01). Since
then
`/Users/sac/smalt/lib/smalt/gcp` and `/Users/sac/smalt/lib/smalt/aws` were added, so `smalt:local`
has not been shown to
build with them. The receipt's build contexts (`ash_r2rml`, `ash_graphlaw`,
`ggen_igniter`) are unchecked for the new tree. Evidence:
`/Users/sac/smalt/docker/BUILD_RECEIPT.md`,
`/Users/sac/smalt/docker/Dockerfile`.

## Acceptance

Run the release-target command from `/Users/sac/smalt/docker/BUILD_RECEIPT.md`; expect exit 0. Then
`docker run --rm smalt:local` health route answers 200 (route in
`/Users/sac/smalt/lib/smalt/health_plug.ex`). Output pasted into a new receipt under
`/Users/sac/smalt/docs/jira/v26.11.14/receipts/`.

## Falsifier

Build exits non-zero, or the new receipt lacks the exact image digest and git SHA.

## Owned files

- /Users/sac/smalt/docker/BUILD_RECEIPT.md
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-18-image.md

## Depends-on

None.

## Size

M

## References (path : LOC)

- /Users/sac/smalt/docker/BUILD_RECEIPT.md : 36 lines
- /Users/sac/smalt/docker/Dockerfile : 165 lines
- /Users/sac/smalt/lib/smalt/gcp/ : 17 files, 3579 lines total
- /Users/sac/smalt/lib/smalt/aws/ : 11 files, 2064 lines total
- /Users/sac/smalt/lib/smalt/health_plug.ex : 101 lines
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-18-image.md : NEW (0 lines, to be created;
  est. LOC: 40; basis: build command, exit, digest, SHA, health output)

## Result

Standing: UNVERIFIED (nothing executed; docker is coordinator-owned; authored by lane W4-11 under this ticket, receipt slots remain PENDING)

Files changed:
- /Users/sac/smalt/docs/jira/v26.11.14/receipts/smalt-18-image.md (new, ~50 LOC, PENDING slots)
- /Users/sac/smalt/docker/BUILD_RECEIPT.md (+7 LOC, refresh pointer)

Acceptance command: the release-target `docker build` in
/Users/sac/smalt/docker/BUILD_RECEIPT.md, then `docker run --rm smalt:local` and
GET /healthz expecting 200; paste exit, digest, git SHA into the receipt.

## Repair

W10-04 applied audit-W8-04 fixes (MED/LOW wording, deadline poll, placeholder disclosure, falsifier tightened). Rerun the acceptance command in ## Result.
