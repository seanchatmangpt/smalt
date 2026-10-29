# Receipt: bknistw3-trivy — NIST W3 / RA-5 trivy image-scan gate, ALIVE

**Standing: ALIVE** — real scans ran, the freshness gate refuses stale scans and
rebuilt images, and both refusal channels were witnessed firing (non-vacuity).

Context: solo. Lane BK-NISTW3, v26.10.22, repo /Users/sac/smalt.

## What landed

| File | What |
|---|---|
| `justfile.d/53-trivy.just` | `trivy-scan` / `trivy-receipt` / `trivy-check` module (33 was taken; per fan-out law the lane added a new module + one root import line). |
| `Justfile` | one import line for the module. |
| `docs/jira/v26.10.22/bench/trivy-receipt.env` | machine-readable scan receipt: `SCAN_DATE` + per-image digests. |

Closes W3 of `bkmkt2-nist-overlay.md` (RA-5 vulnerability scanning: ABSENT →
SATISFIED at the image-scan mechanism level, receipt-gated).

## Mechanism

- `trivy-scan`: scans `smalt-substrate:bkimg` + `smalt-console:bkimg` with
  `--severity CRITICAL,HIGH --scanners vuln`, JSON reports to `tmp/trivy/`.
  **Gate counts CRITICALs from the real JSON report** — trivy exits 0 even with
  findings by default, so exit-code-trusting would be a vacuous gate (witnessed:
  the first version printed "clean" while displaying 12 HIGH findings). HIGH is
  reported; CRITICAL > 0 fails the recipe.
- `trivy-receipt`: writes `SCAN_DATE=YYYY-MM-DD` + `DIGEST_<img>=sha256:…`
  (from real `docker image inspect`) to `docs/jira/v26.10.22/bench/trivy-receipt.env`.
- `trivy-check`: fail-closed freshness gate — receipt must exist, `SCAN_DATE`
  < 7 days old, and every digest must match the current local image. Typed
  `TRIVY-CHECK-REFUSE` reasons; trivy absent → `TRIVY-ABSENT: … brew install trivy`.

## Embedded execution output (2026-10-22, trivy 0.67.2)

```
trivy smalt-substrate:bkimg: CRITICAL=0 HIGH=0
trivy smalt-console:bkimg:   CRITICAL=0 HIGH=12
trivy-scan: done (gate: CRITICAL==0)

trivy-check: OK (scan 2026-10-22, 0d old, digests match)   # exit 0
```

Console HIGH inventory (real JSON, `tmp/trivy/smalt-console_bkimg.json`):
brace-expansion ×5 (CVE-2026-102276/102278/13149/14257/69152), braces
CVE-2026-93687, http-cache-semantics CVE-2026-93748, ip-address CVE-2026-69192,
pacote ×2 CVE-2026-9496, picomatch CVE-2026-33671, sigstore CVE-2026-48815.
Substrate: zero findings. Zero CRITICALs on either image.

## Non-vacuity (refusals witnessed, receipt restored green after each probe)

```
# SCAN_DATE touched to 2026-10-14 (8 days old):
TRIVY-CHECK-REFUSE: scan is 8 days old (>= 7); re-scan: just trivy-scan && just trivy-receipt
exit 1

# substrate digest touched to sha256:DEAD (simulated rebuild):
TRIVY-CHECK-REFUSE: images rebuilt since scan: [('smalt-substrate:bkimg', 'sha256:DEAD', 'sha256:2880b5e5f8172b4e299')]; re-scan
exit 1

# trivy masked from PATH:
TRIVY-ABSENT: trivy not found on PATH. Install: brew install trivy
exit 1

# receipt restored via just trivy-receipt: trivy-check OK again
```

## Notes / boundary

- just recipes cannot indent deeper than the recipe base and a recipe whose
  body starts with a non-shebang line loses shebang treatment (witnessed: the
  body's `import` resolved to ImageMagick's `import`) — hence the flat-python
  style and inlined guards.
- The `.env` receipt's digest rows key images by `tr ':/-' '___'`; the checker
  mirrors that. Tag-pinned (bkimg), so digests are the real identity anchor.
- RA-5 remains PARTIAL as a program: this gates the two BK-IMG images only;
  W3's original sync-gate coupling (refuse manifest regen when newest scan
  predates the image fact) is future work.
