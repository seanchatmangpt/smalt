# i29 — ws-lint / ws-build / ws-court / cli-test fresh verification legs

- Date: 2026-10-18
- Subject: /Users/sac/smalt, HEAD `d1298be` at run time (tree has advanced past `0009df3` since tasking; task said "post-0009df3 tree" — d1298be is a descendant on main).
- Context: solo (lane i29, exclusive use of workspace gates and cli-test venvs during run)
- No source edits; no _build deletion. One environment bootstrap: `npm ci` in
  `/Users/sac/smalt/workspace` (node_modules was absent — first `just ws-lint` exited 127
  `eslint: command not found` before the bootstrap).

## Standing: PASS (all four legs green)

## 1. just ws-lint — exit 0

```
✖ 29 problems (0 errors, 29 warnings)
WS-LINT_EXIT=0
```

(29 warnings, all `@typescript-eslint/no-unused-vars`-class; 0 errors.)

## 2. just ws-build — exit 0

```
WS-BUILD_EXIT=0
```

Full route table rendered (static/SSG/dynamic as designed); tail of build output shows
prerendered `/bench/news/*` SSG paths and `ƒ Proxy (Middleware)`.

## 3. just ws-court — exit 0

```
# court verdict
# PASS=50 FAIL=0 SKIP=2
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
# SKIP: live: ARM read-only probe: no smalt substrate on http://127.0.0.1:9443 (UND_ERR_SOCKET) — live leg not run
WS-COURT_EXIT=0
```

Both SKIPs are loud and typed (node-executability + no-substrate). Live ARM probe leg not
run (substrate down during the court — expected for a solo workspace-gate lane).

## 4. just cli-test — exit 0

```
== SDK wire lanes (tests/) via .venv-cli ==
.................s.............................s                         [100%]
46 passed, 2 skipped, 6 warnings in 74.86s (0:01:14)
== package lanes (smalt_cli/test_*.py) via .venv-cli (ADR-PY-002 fallback) ==
........................................................................ [ 70%]
..............................                                           [100%]
102 passed, 6 warnings in 140.37s (0:02:20)
CLI-TEST_EXIT=0
```

Totals: 148 passed, 2 skipped, 0 failed. Warnings are pre-existing classes
(urllib3 InsecureRequestWarning on 127.0.0.1 TLS; PyJWT InsecureKeyLengthWarning on short
test HMAC keys).

## Notes

- First `just cli-test` attempt was moved to background and killed at the 30-minute
  background cap while the `.venv-cli` wire-lane leg was still running (it had consumed
  ~3s CPU over ~25 min — consistent with heavy loopback contention from another lane's
  concurrent pytest on the same machine, not a smalt-cli defect). Fresh re-run completed
  in 3m35s total. No failures in either attempt's completed portion.
- Machine: `just bench-machine` →
  `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
