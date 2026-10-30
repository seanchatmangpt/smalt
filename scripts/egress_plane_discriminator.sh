#!/bin/sh
# egress_plane_discriminator.sh — G35-1/G35-2 discriminating court
# (per /Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/35-egress-mapping-decision.md)
#
# Answers ONE question: which plane/port answers from the host, and is the
# GAP11 (8443 egress NodePort) deferral still valid?
#
# Exit contract:
#   0 = DEFER VALID   — ARM plane answers on 9443; host 8443 does NOT answer
#                       with the kind backend; no 30843 docker mapping exists.
#   1 = DEFER VOID — APPLY PRE-STAGED FIX
#                     (kind-config diff in gaps/35: host 18443 -> containerPort
#                     30843, then recreate + re-bootstrap). Fired when the
#                     30843 mapping exists (deferred state over) or when a WAVE
#                     consumer adds a host->8443 dependency.
#   2 = INCONCLUSIVE  — cluster/container not reachable; no verdict either way.
#                      (ARM 9443 not answering is also inconclusive here: this
#                      script cannot distinguish native-beam vs kind backend —
#                      the native substrate may own 9443. See gaps/17 finding 2.)
#
# NOTE: a native host beam answering on 8443 is the NATIVE substrate, not the
# kind backend. G35-1 alone cannot name the plane; the kubectl/docker mapping
# cross-check (G35-2) is what makes the verdict mechanical.

set -u

CLUSTER_CONTAINER="${SMALT_CLUSTER_CONTAINER:-smalt-control-plane}"

echo "== G35 egress plane discriminator =="
echo "-- G35-1: plane discriminator --"

arm_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1:9443/health 2>/dev/null)
if [ "${arm_code:-000}" = "000" ]; then
  # TLS face may be unprovisioned on the kind backend; try plain HTTP.
  arm_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:9443/health 2>/dev/null)
  arm_via="http"
else
  arm_via="https"
fi
echo "ARM 9443 /health -> HTTP ${arm_code:-000} (${arm_via}; any HTTP answer incl. 401 = plane alive)"

dp_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8443/health 2>/dev/null)
if [ "${dp_code:-000}" = "000" ]; then
  echo "host 8443 /health -> no HTTP answer (refused/timeout)"
  dp="NO-ANSWER"
else
  echo "host 8443 /health -> HTTP ${dp_code}"
  echo "   (which plane answered is not attributable from this probe alone;"
  echo "    the native host beam may own 127.0.0.1:8443 — see G35-2 + gaps/17 finding 2)"
  dp="ANSWERED-${dp_code}"
fi

echo "-- G35-2: mapping existence (mechanical defer-flip trigger) --"
if docker port "$CLUSTER_CONTAINER" 2>/dev/null | grep -q 30843; then
  echo "G35: MAPPED (deferred state over; option (a) landed)"
  mapped=1
else
  echo "G35: UNMAPPED (GAP11 stands, deferral valid)"
  mapped=0
fi

echo "-- verdict --"
# ARM plane must be alive for any verdict at all.
if [ "$arm_code" = "000" ]; then
  echo "INCONCLUSIVE: ARM plane (9443) not answering; no verdict (exit 2)"
  exit 2
fi

if [ "$mapped" -eq 1 ]; then
  echo "DEFER VOID: 30843 mapping exists -> apply pre-staged gaps/35 diff (host 18443 -> 30843), recreate, re-run (exit 1)"
  exit 1
fi

case "$dp" in
  NO-ANSWER)
    echo "DEFER VALID: ARM answers on 9443; host 8443 does not answer with a backend; no 30843 mapping (exit 0)"
    exit 0
    ;;
  *)
    echo "DEFER VALID WITH CAVEAT: something answers on host 8443 but it is NOT the kind backend (no 30843 mapping) — native substrate owns the port; GAP11 deferral stands (exit 0)"
    exit 0
    ;;
esac
