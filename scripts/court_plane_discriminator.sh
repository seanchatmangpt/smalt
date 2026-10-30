#!/usr/bin/env bash
# court_plane_discriminator.sh — GAP09/G17: which plane answers the court's
# metadata anchor (host 127.0.0.1:9443 /metadata/endpoints)?
#
# Body-signature caveat (live-witnessed 2026-10-30): the /metadata/endpoints
# body ECHOES THE REQUEST HOST HEADER (advertising base URL), so a plain
# body diff is NOT a plane signature — a native beam and the kind pod return
# identical bytes for identical Host headers. The grounded signature is:
#   1. socket ownership on the host for the probe port (lsof), plus
#   2. advertised-endpoint comparison: probe host loopback with Host:
#      127.0.0.1:9443 vs probe the pod IP in-cluster with the SAME Host
#      header — two distinct servers produce distinct advertised bodies
#      only if the server derives its advertisement from its own config,
#      which it does NOT here. Therefore: ownership is decisive, the
#      two-probe liveness cross-check is corroborating.
#
# Verdict:
#   NATIVE — host probe port owned by a beam.smp whose cwd is the repo
#            (the G17 native beam, lane-orphaned: ppid=1 under launchd)
#   KIND   — host probe port owned by a tunnel/proxy (ssh mux, docker-proxy,
#            kubectl port-forward) while an in-cluster pod serves the anchor
#   SPLIT  — host loopback owned by beam.smp AND an in-cluster pod also
#            serving (the live witnessed state: both planes up)
#   NONE   — nothing answers either plane
#   exit:  0 NATIVE | 2 KIND/SPLIT | 3 NONE/UNKNOWN (fail-closed)
set -uo pipefail
PORT="${1:-9443}"
CTX="${KCTX:-kind-smalt}"
NS="${NS:-default}"
LABEL_SVC="${LABEL_SVC:-smalt-backend-headless}"
REPO="${REPO:-/Users/sac/smalt}"

host_owner() { # pid command cwd for the most specific listener on 127.0.0.1:$PORT
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk -v p=":$PORT" '$9 ~ /127\.0\.0\.1/ || $9 ~ /\*/'
}

echo "[DISCRIMINATOR] port=$PORT ctx=$CTX repo=$REPO"

host_body=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/metadata/endpoints" || true)
host_code=$([ -n "$host_body" ] && echo 200 || echo 000)
echo "[DISCRIMINATOR] host 127.0.0.1:$PORT probe: HTTP $host_code (${#host_body} bytes)"

pod_probe() {
  kubectl --context "$CTX" -n "$NS" exec smalt-backend-0 -c smalt -- \
    curl -s --max-time 3 -o /dev/null -w '%{http_code}' \
    "http://10.244.1.11:$PORT/metadata/endpoints" 2>/dev/null
}
pod_code=$(pod_probe)
echo "[DISCRIMINATOR] in-cluster pod-IP probe: HTTP $pod_code"

# Enumerate ALL listeners; classify each (beam.smp = native candidate,
# ssh/docker-proxy/kubectl = tunnel candidate — colima's ssh mux IS the kind
# path when docker context is colima: host *:9443 -> VM -> docker-proxy -> node).
beam_pid=""
tunnel_pids=""
while read -r l; do
  pid=$(echo "$l" | awk '{print $2}')
  cmd=$(echo "$l" | awk '{print $1}')
  case "$cmd" in
    beam.smp) beam_pid="$pid" ;;
    ssh|docker-proxy|kubectl|com.dock*) tunnel_pids="$tunnel_pids $pid" ;;
  esac
done < <(host_owner)

beam_cwd=""
if [ -n "$beam_pid" ]; then
  beam_cwd=$(lsof -a -p "$beam_pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)
fi
echo "[DISCRIMINATOR] listeners: beam pid=${beam_pid:-none} (cwd=${beam_cwd:-n/a}), tunnel pids=${tunnel_pids:-none}"

verdict=3; name=UNKNOWN
if [ -n "$beam_pid" ]; then
  if [ "$pod_code" = 200 ]; then
    verdict=2; name=SPLIT
  else
    verdict=0; name=NATIVE
  fi
elif [ -n "${tunnel_pids// /}" ] && [ "$pod_code" = 200 ]; then
  verdict=2; name=KIND
elif [ "$pod_code" = 200 ]; then
  verdict=2; name=KIND
else
  verdict=3; name=NONE
fi

echo "[DISCRIMINATOR] PLANE=$name (exit $verdict)"
exit "$verdict"
