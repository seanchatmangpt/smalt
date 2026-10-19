#!/usr/bin/env python3
"""Unittest runner for the smalt invariant gates (gates/*.py).

Each gate is executed for real: it boots its own smalt substrate on probed
private ports (MIX_ENV=test, SMALT_TEST_*_PORT), exercises the invariant over
the live wire surface, applies its negative fixtures, and writes a verdict
receipt to tmp/invariant-gates/<gate>-receipt.json. The test asserts the gate
exited 0 (positive held AND every negative fixture was refused) and that the
receipt on disk says PASS with every fixture detected — a green receipt only
when the negative fixtures were actually detected.
"""
import json
import os
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATES = os.path.join(REPO, "gates")
RECEIPT_DIR = os.path.join(REPO, "tmp", "invariant-gates")

GATES_UNDER_TEST = [
    "cosmos-etag-cas",
    "blob-worm",
    "ledger-chain",
    "queue-capacity",
    "lock-clamp",
    "appconfig-etag-cas",
]
FILES = {
    "cosmos-etag-cas": "cosmos_etag_cas_gate.py",
    "blob-worm": "blob_worm_gate.py",
    "ledger-chain": "ledger_chain_gate.py",
    "queue-capacity": "queue_capacity_gate.py",
    "lock-clamp": "lock_clamp_gate.py",
    "appconfig-etag-cas": "appconfig_etag_cas_gate.py",
}


class InvariantGatesTest(unittest.TestCase):
    def test_all_invariant_gates(self):
        """Every gate: real substrate run -> exit 0, receipt PASS, negatives refused."""
        for name in GATES_UNDER_TEST:
            with self.subTest(gate=name):
                path = os.path.join(GATES, FILES[name])
                r = subprocess.run(
                    [sys.executable, path],
                    cwd=REPO,
                    capture_output=True,
                    text=True,
                    timeout=900,
                )
                self.assertEqual(
                    r.returncode, 0,
                    msg=f"gate {name} failed\nstdout:\n{r.stdout}\nstderr:\n{r.stderr}")

                receipt_path = os.path.join(RECEIPT_DIR, f"{name}-receipt.json")
                self.assertTrue(os.path.exists(receipt_path),
                                f"missing receipt {receipt_path}")
                with open(receipt_path) as f:
                    receipt = json.load(f)
                self.assertEqual(receipt["verdict"], "PASS",
                                 msg=f"receipt verdict: {receipt}")
                self.assertEqual(receipt["positive"], "PASS")
                self.assertTrue(receipt["fixtures"],
                                msg="gate declared no negative fixtures")
                for fixture in receipt["fixtures"]:
                    self.assertTrue(
                        fixture["detected"],
                        msg=f"fixture {fixture['fixture']} not detected: {receipt}")


class DocContractTest(unittest.TestCase):
    """Doc-as-contract courts (DX lane cycles 2/8): docs must match reality.

    Concurrent lanes repeatedly reverted the FIRST_RUN court tier list
    (T0..T4 is wrong — there is no T0); this court makes the revert a red
    test instead of silent doc rot.
    """

    def _read(self, *parts):
        with open(os.path.join(REPO, *parts)) as f:
            return f.read()

    def test_first_run_court_tiers_are_t1_to_t4(self):
        text = self._read("docs", "FIRST_RUN.md")
        self.assertNotIn("T0..T4", text)
        self.assertIn("T1..T4", text)

    def test_just_reference_tf_smoke_exit_contract(self):
        row = self._read("docs", "JUST_REFERENCE.md")
        # tf_smoke.sh documents exits 0/1/2/77; the reference must carry all
        # four (77 = SKIPPED-NETWORK, court intentionally fails offline).
        self.assertIn("77 SKIPPED-NETWORK", row)
        self.assertIn("tf_smoke.sh", row)


if __name__ == "__main__":
    unittest.main(verbosity=2)
