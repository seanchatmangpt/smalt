"""WF5 — ARM throttle gate on a private substrate booted with
arm_rate_limit=20 (boot-eval put_env, enforce mode).

200 burst GETs via ThreadPoolExecutor -> >=1 x 429 TooManyRequests with a
Retry-After header. Zero 429s against a declared finite limit is a FAIL
(SUBSTRATE_THROTTLE_DISABLED). An infinite-limit substrate is a loud exit 4.
"""
import os
import time
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

import pytest

from conftest import ssl_ctx
from harness.errors import EXCEPTION_TABLE  # noqa: F401  (typed-table witness)

pytestmark = pytest.mark.enforce

BURST = 200


def _token(arm):
    body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": "py-verify-lane",
        "client_secret": "py-verify-lane-secret",
    }).encode()
    req = urllib.request.Request(
        f"{arm}/oauth2/v2.0/token", data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    import json

    with urllib.request.urlopen(req, timeout=15, context=ssl_ctx) as resp:
        return json.loads(resp.read())["access_token"]


def test_arm_rate_limit_429(throttle_arm):
    if os.environ.get("SMALT_WF5_ASSUME_INFINITE"):
        # Loud typed exit: a caller that pinned an infinite-limit substrate
        # cannot exercise this test — never a fake pass.
        pytest.exit(
            "WF5 SKIP-LOUD: substrate arm_rate_limit is :infinity — throttle "
            "gate not exercisable", returncode=4,
        )

    tok = _token(throttle_arm)

    def hit(_):
        req = urllib.request.Request(
            f"{throttle_arm}/subscriptions?api-version=2021-04-01",
            headers={"Authorization": f"Bearer {tok}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15, context=ssl_ctx) as r:
                return r.status, dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers)

    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=32) as pool:
        results = list(pool.map(hit, range(BURST)))
    elapsed = time.monotonic() - started

    codes = [c for c, _ in results]
    limited = [(c, h) for c, h in results if c == 429]
    assert limited, (
        "SUBSTRATE_THROTTLE_DISABLED: 0 x 429 across a 200-hit burst against a "
        f"declared finite arm_rate_limit=20 (codes: ok={codes.count(200)}, "
        f"other={sorted(set(codes) - {200, 429})})"
    )
    retry_after = [h.get("retry-after") or h.get("Retry-After") for _, h in limited]
    assert all(retry_after), f"429 responses missing Retry-After: {retry_after[:5]}"
    assert codes.count(200) >= 1, "throttle refused EVERY request — gate is not a window"
    print(f"[wf5] burst 200 in {elapsed:.2f}s: {codes.count(200)} x 200, "
          f"{len(limited)} x 429 (retry-after={retry_after[0]})")
