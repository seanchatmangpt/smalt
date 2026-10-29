# trivy image-scan gate (NIST W3 / RA-5 vulnerability scanning) — lane BK-NISTW3
# Images are the BK-IMG production-honest builds (Dockerfile.smalt / Dockerfile.console).
# Receipt: docs/jira/v26.10.22/receipts/bknistw3-trivy.md

trivy_images := 'smalt-substrate:bkimg smalt-console:bkimg'
trivy_receipt := 'docs/jira/v26.10.22/bench/trivy-receipt.env'

# fail-closed prereq: trivy must be on PATH
[private]
_require-trivy:
    #!/usr/bin/env sh
    if ! command -v trivy >/dev/null 2>&1; then echo "TRIVY-ABSENT: trivy not found on PATH. Install: brew install trivy" >&2; exit 1; fi

# scan both BK-IMG images (CRITICAL,HIGH); fail-closed on any CRITICAL finding.
# trivy exits 0 even with findings by default, so the gate counts CRITICALs from
# the real JSON report instead of trusting the exit code.
trivy-scan:
    #!/usr/bin/env sh
    _trivy_guard() { if ! command -v trivy >/dev/null 2>&1; then echo "TRIVY-ABSENT: trivy not found on PATH. Install: brew install trivy" >&2; exit 1; fi; }
    _trivy_guard
    mkdir -p tmp/trivy
    rc=0
    for img in {{trivy_images}}; do f="tmp/trivy/$(echo "${img}" | tr ':/' '__').json"; echo "=== trivy image ${img} ==="; trivy image --severity CRITICAL,HIGH --scanners vuln --format json --output "${f}" "${img}" || rc=1; crit=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for r in (d.get('Results') or []) for v in (r.get('Vulnerabilities') or []) if v.get('Severity')=='CRITICAL'))" "${f}"); high=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for r in (d.get('Results') or []) for v in (r.get('Vulnerabilities') or []) if v.get('Severity')=='HIGH'))" "${f}"); echo "trivy ${img}: CRITICAL=${crit} HIGH=${high}"; if [ "${crit}" != "0" ]; then rc=1; fi; done
    if [ "${rc}" -ne 0 ]; then echo "TRIVY-SCAN-FAIL: CRITICAL findings present (fail-closed). Full JSON: tmp/trivy/." >&2; exit 1; fi
    echo "trivy-scan: done (gate: CRITICAL==0)"

# write the dated scan receipt (scan date + image digests); run AFTER trivy-scan
trivy-receipt:
    #!/usr/bin/env sh
    _trivy_guard() { if ! command -v trivy >/dev/null 2>&1; then echo "TRIVY-ABSENT: trivy not found on PATH. Install: brew install trivy" >&2; exit 1; fi; }
    _trivy_guard
    out={{trivy_receipt}}
    mkdir -p "$(dirname "${out}")"
    {
    echo "# trivy scan receipt — machine-readable (NIST W3); regen with just trivy-receipt"
    echo "SCAN_DATE=$(date +%Y-%m-%d)"
    for img in {{trivy_images}}; do key=$(echo "${img}" | tr ':/-' '___'); dig=$(docker image inspect "${img}" | sed -n 's/.*"Id": "\([^"]*\)".*/\1/p'); echo "DIGEST_${key}=${dig}"; done
    } > "${out}"
    cat "${out}"

# fail-closed freshness gate: receipt must exist, scan date < 7 days old,
# and recorded digests must match the current images (stale scan or rebuilt image refuses)
trivy-check:
    #!/usr/bin/env python3
    import json, os, re, shutil, subprocess, sys
    from datetime import date
    if shutil.which("trivy") is None: print("TRIVY-ABSENT: trivy not found on PATH. Install: brew install trivy", file=sys.stderr); sys.exit(1)

    receipt = "{{trivy_receipt}}"
    max_age = 7
    text = open(receipt).read() if os.path.exists(receipt) else None
    if text is None: print(f"TRIVY-CHECK-REFUSE: no receipt at {receipt}; run `just trivy-scan && just trivy-receipt`", file=sys.stderr); sys.exit(1)

    m = re.search(r"^SCAN_DATE=(\d{4}-\d{2}-\d{2})$", text, re.M)
    if not m: print("TRIVY-CHECK-REFUSE: receipt has no SCAN_DATE line", file=sys.stderr); sys.exit(1)
    scan = date.fromisoformat(m.group(1))
    age = (date.today() - scan).days
    if age >= max_age: print(f"TRIVY-CHECK-REFUSE: scan is {age} days old (>= {max_age}); re-scan: just trivy-scan && just trivy-receipt", file=sys.stderr); sys.exit(1)

    results = [(img, re.search(rf"^DIGEST_{key}=(\S+)$", text, re.M), subprocess.run(["docker", "image", "inspect", img], capture_output=True, text=True)) for (key, img) in [(re.sub(r"[:/\-]", "_", img), img) for img in "{{trivy_images}}".split()]]
    if any(x[1] is None for x in results): print(f"TRIVY-CHECK-REFUSE: no digest row for {[x[0] for x in results if x[1] is None]}", file=sys.stderr); sys.exit(1)
    if any(x[2].returncode != 0 for x in results): print(f"TRIVY-CHECK-REFUSE: images not present locally: {[x[0] for x in results if x[2].returncode != 0]}; re-scan", file=sys.stderr); sys.exit(1)
    mismatched = [(x[0], x[1].group(1), json.loads(x[2].stdout)[0]["Id"]) for x in results if json.loads(x[2].stdout)[0]["Id"] != x[1].group(1)]
    if mismatched: print(f"TRIVY-CHECK-REFUSE: images rebuilt since scan: {[(n, r[:26], c[:26]) for (n, r, c) in mismatched]}; re-scan", file=sys.stderr); sys.exit(1)
    print(f"trivy-check: OK (scan {scan}, {age}d old, digests match)")
