"""Deadline-bounded poll — the lane's ONLY wait primitive (no-sleep law).

poll_until(fun, timeout_s, poll_s): evaluate `fun` on an interval until it
returns truthy; raise TimeoutError with the last falsy result at deadline.
"""
import time


def poll_until(fun, timeout_s, poll_s=0.2):
    """Poll `fun` until truthy or deadline. Returns fun()'s truthy result.

    Bounded, observation-based — never a fixed sleep-as-wait.
    """
    deadline = time.monotonic() + float(timeout_s)
    last = None
    while True:
        last = fun()
        if last:
            return last
        if time.monotonic() >= deadline:
            raise TimeoutError(f"poll_until exhausted after {timeout_s}s; last={last!r}")
        time.sleep(poll_s)
