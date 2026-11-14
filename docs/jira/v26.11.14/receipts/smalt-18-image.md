# smalt-18 image build receipt (2026-11-14)

Standing: UNVERIFIED

No build was executed by lane W4-11 (docker/git are coordinator-owned). The fields below are
slots the coordinator fills from real output; the receipt is invalid while any slot reads PENDING.

## Subject

- Ticket: `/Users/sac/smalt/docs/jira/v26.11.14/smalt-18.md`
- Git SHA: PENDING (`git -C /Users/sac/smalt rev-parse HEAD`)
- New trees under test: `lib/smalt/gcp` (17 files), `lib/smalt/aws` (11 files)
- Build contexts: `ash_r2rml`, `ash_graphlaw`, `ggen_igniter`

## Build (release target)

```sh
cd /Users/sac/smalt
docker build -f docker/Dockerfile -t smalt:local . \
  --build-context ash_r2rml=$HOME/ash_r2rml \
  --build-context ash_graphlaw=$HOME/ash_graphlaw \
  --build-context ggen_igniter=$HOME/ggen_igniter
echo "exit=$?"
```

- Exit: PENDING (expect 0)
- Image digest: PENDING (`docker image inspect smalt:local --format '{{.Id}}'`)
- Label `org.smalt.subject`: PENDING (must equal Git SHA above)

## Health route

Route source: `/Users/sac/smalt/lib/smalt/health_plug.ex` (`GET /healthz` 200 ready / 503
degraded; `GET /healthz/live` always 200).

```sh
docker run --rm -d --name smalt18 -p 8443:8443 smalt:local
# poll with a deadline, never a fixed sleep:
deadline=$(( $(date +%s) + 60 ))
until curl -ksf https://localhost:8443/healthz/live; do [ "$(date +%s)" -ge "$deadline" ] && { echo "health deadline exceeded"; break; }; done
curl -ks -o /dev/null -w '%{http_code}\n' https://localhost:8443/healthz
docker rm -f smalt18
```

- `/healthz` status: PENDING (expect 200)

Port 8443 https: from health_plug.ex:73 comment (first-mounted plug on 8443); the TLS
scheme is UNVERIFIED until the container run records `/healthz/live` output.
Build-context dirs (`$HOME/ash_r2rml`, `ash_graphlaw`, `ggen_igniter`) must exist; check with `ls -d` first.

## Falsifier

Build exits non-zero, or this receipt lacks the exact image digest and git SHA.
