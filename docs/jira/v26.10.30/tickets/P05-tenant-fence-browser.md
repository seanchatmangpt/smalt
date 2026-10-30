# P05 — Cross-tenant breach prevention witnessed from the browser

- window: v26.10.30 · id: CLM-06 (Scenario 4) · receipt: r-p05-tenant-fence-browser.md
- depends: L07 fence restoration.

## Claim

An authenticated tenant-A session attacking tenant-B's API surface receives
typed 403 with no data in the error payload — the same fence law the
tenant_fence courts pin, now witnessed through the full
browser -> ingress -> egress path.

## Falsifier

Any 200/404-lie on the foreign path.
