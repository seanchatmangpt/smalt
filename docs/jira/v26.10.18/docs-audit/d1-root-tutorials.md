# D1 — README + tutorials + getting-started audit (2026-10-18)
Stale claims: README:223-226 "Five fail-closed gates" (now six — appconfig-etag-cas; README:34 contradicts); README:288 eh-run ports (19443/18443/15672 vs actual 39172/39173/39444); README:13 Standing dated 10-16; enclave-lifecycle.md "28 tables/17 resource-bearing" (now 33/22).
Wrong/dead commands: dev-loop.md:9 "(just ingress)" dead; dev-loop.md:181 `just cli-gates` is [private] — not user-runnable; dev-loop:20 "29445-29449" -> 29445-29450.
Missing features (8): SMALT_PLANES plane loader; azsim tier (10 test files + just azsim-sdk); burn suite (9 recipes); zero-sleep doctrine + sleep gate; stress tier; budget gate; hex-only ex4pm; canonical SmaltTest foundations. Plus ~20 undocumented recipes.
Clean: every README command resolves; no dead paths; client matrix accurate.
