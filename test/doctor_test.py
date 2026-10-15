#!/usr/bin/env python3
"""Stdlib unittest suite for scripts/doctor.py — real sockets, real state."""
import socket
import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import doctor  # noqa: E402
import subprocess  # noqa: E402
import os  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402


class GitignoreFixTest(unittest.TestCase):
    def _temp_repo(self):
        d = tempfile.mkdtemp(prefix="smalt-doctor-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return Path(d)

    def test_fix_appends_missing_entries(self):
        root = self._temp_repo()
        (root / ".gitignore").write_text("/_build/\n")
        f = doctor.DiagnosticFailure("gitignore-coverage", "missing", "# fix",
                                     fix=doctor.fix_append_gitignore)
        action = f.fix(root)
        self.assertIn("6 missing entries", action)
        content = (root / ".gitignore").read_text()
        for line in doctor.REQUIRED_GITIGNORE.values():
            self.assertIn(line, content)
        self.assertTrue(content.startswith("/_build/\n"), content)

    def test_fix_idempotent_second_call_returns_none(self):
        root = self._temp_repo()
        doctor.fix_append_gitignore(root)
        self.assertIsNone(doctor.fix_append_gitignore(root))

    def test_check_passes_after_fix(self):
        root = self._temp_repo()
        doctor.fix_append_gitignore(root)
        # check_gitignore reads REPO_ROOT, so assert via the same logic directly
        have = {ln.strip() for ln in (root / ".gitignore").read_text().splitlines()}
        missing = [ln for ln in doctor.REQUIRED_GITIGNORE.values() if ln not in have]
        self.assertEqual(missing, [])


class DevKeyPermsFixTest(unittest.TestCase):
    def test_chmod_tightens_open_key(self):
        d = tempfile.mkdtemp(prefix="smalt-doctor-keys-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        key = Path(d) / "dev-key.pem"
        key.write_text("-----BEGIN PRIVATE KEY-----\n")
        os.chmod(key, 0o644)
        action = doctor.fix_chmod_dev_keys([key])
        self.assertIn("0o600", action)
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        # idempotent: second pass changes nothing
        self.assertIsNone(doctor.fix_chmod_dev_keys([key]))


class TmpDirsFixTest(unittest.TestCase):
    def test_creates_missing_dirs(self):
        d = Path(tempfile.mkdtemp(prefix="smalt-doctor-tmp-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        tmp = d / "tmp"
        stability = tmp / "stability"
        action = doctor.fix_create_tmp_dirs([tmp, stability])
        self.assertIn("created", action)
        self.assertTrue(stability.is_dir())
        self.assertIsNone(doctor.fix_create_tmp_dirs([tmp, stability]))


class CertMintIdempotencyTest(unittest.TestCase):
    def test_mint_then_reuse(self):
        cert_dir = Path(tempfile.mkdtemp(prefix="smalt-doctor-certs-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(cert_dir, ignore_errors=True))
        env = dict(os.environ, SMALT_CERT_DIR=str(cert_dir))
        outs = []
        for _ in range(2):
            outs.append(subprocess.run(
                ["bash", str(doctor.CERT_SCRIPT)],
                capture_output=True, text=True, env=env, timeout=60))
        self.assertEqual(outs[0].returncode, 0, outs[0].stderr)
        self.assertIn("minted", outs[0].stdout)
        self.assertEqual(outs[1].returncode, 0, outs[1].stderr)
        self.assertIn("reusing", outs[1].stdout)
        for name in ("ca-cert.pem", "dev-cert.pem", "dev-key.pem"):
            self.assertTrue((cert_dir / name).exists(), name)
        self.assertEqual((cert_dir / "dev-key.pem").stat().st_mode & 0o777, 0o600)


class ReceiptFreshnessTest(unittest.TestCase):
    def test_stale_receipt_detected(self):
        d = Path(tempfile.mkdtemp(prefix="smalt-doctor-rcpt-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        rcpt = d / "gate-receipt.json"
        rcpt.write_text("{}")
        stale_ts = time.time() - 25 * 3600
        os.utime(rcpt, (stale_ts, stale_ts))
        # receipt_ages globs doctor.TMP_DIR; replicate glob semantics against temp dir
        ages = [(p, time.time() - p.stat().st_mtime) for p in d.glob("*receipt*.json")]
        self.assertEqual(len(ages), 1)
        self.assertGreater(ages[0][1], doctor.RECEIPT_STALE_SECONDS)
        self.assertTrue(doctor.check_recent_receipts().startswith("INFO"))


class GenDevCertPermsTest(unittest.TestCase):
    """F4 court: the minter never emits key material wider than 0600."""

    def test_fresh_mint_all_keys_0600(self):
        cert_dir = Path(tempfile.mkdtemp(prefix="smalt-doctor-umask-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(cert_dir, ignore_errors=True))
        env = dict(os.environ, SMALT_CERT_DIR=str(cert_dir))
        r = subprocess.run(["bash", str(doctor.CERT_SCRIPT)],
                           capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in ("dev-key.pem", "ca-key.pem"):
            mode = (cert_dir / name).stat().st_mode & 0o777
            self.assertEqual(mode, 0o600, f"{name} minted {oct(mode)}")

    def test_reuse_path_self_heals_legacy_open_key(self):
        cert_dir = Path(tempfile.mkdtemp(prefix="smalt-doctor-legacy-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(cert_dir, ignore_errors=True))
        env = dict(os.environ, SMALT_CERT_DIR=str(cert_dir))
        subprocess.run(["bash", str(doctor.CERT_SCRIPT)],
                       capture_output=True, text=True, env=env, timeout=60)
        os.chmod(cert_dir / "dev-key.pem", 0o644)  # simulate pre-umask-077 key
        r = subprocess.run(["bash", str(doctor.CERT_SCRIPT)],
                           capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("reusing", r.stdout)
        self.assertEqual((cert_dir / "dev-key.pem").stat().st_mode & 0o777, 0o600)


class DoctorFailClosedTest(unittest.TestCase):
    """Mutation court: a failing check MUST flip the doctor's exit to 1."""

    def test_broken_check_forces_exit_1(self):
        r = subprocess.run(
            [sys.executable, "-c",
             "import sys, doctor; "
             "doctor.CHECK_REGISTRY.insert(0, "
             "  ('injected-fault', lambda: (_ for _ in ()).throw("
             "    doctor.DiagnosticFailure('injected-fault', 'mutation: injected fault',"
             "                             '# mutate')), None)); "
             "doctor.main()"],
            capture_output=True, text=True, timeout=120,
            cwd=str(Path(__file__).resolve().parent.parent / "scripts"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("injected-fault", r.stdout)

    def test_all_pass_registry_exits_0(self):
        # Symmetry half of the fail-closed contract: a court whose checks all
        # pass must exit 0. Asserted through the real main() on a synthetic
        # registry (ambient ports on a shared checkout are not repo health).
        argv = sys.argv
        registry = doctor.CHECK_REGISTRY
        try:
            sys.argv = ["doctor.py"]
            doctor.CHECK_REGISTRY = [("always-pass", lambda: "ok", None)]
            with self.assertRaises(SystemExit) as ctx:
                doctor.main()
            self.assertEqual(ctx.exception.code, 0)
        finally:
            sys.argv = argv
            doctor.CHECK_REGISTRY = registry


class V1ProjectionTest(unittest.TestCase):
    def test_v1_shape_preserved(self):
        checks = [{"name": "binaries", "status": "PASS", "detail": "ok"}]
        v1 = doctor.v1_projection(checks, True)
        self.assertEqual(v1["schema"], "smalt-doctor/v1")
        self.assertEqual(list(v1.keys()), ["schema", "ok", "checks"])
        self.assertNotIn("duration_ms", v1["checks"][0])

    def test_v2_registry_has_new_checks(self):
        names = [name for name, _, _ in doctor.CHECK_REGISTRY]
        for required in ("gitignore-coverage", "dev-key-perms", "dev-certs",
                         "tmp-dirs", "mix-deps-freshness", "recent-receipts",
                         "keychain-trust"):
            self.assertIn(required, names)



def free_listener():
    """Bind a listener to an ephemeral port; returns (sock, port)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    return s, s.getsockname()[1]


def responder(sock, reply=None):
    """Accept one connection in a thread; read 8 bytes; optionally reply then close."""

    def run():
        try:
            conn, _ = sock.accept()
            conn.recv(8)
            if reply is not None:
                conn.sendall(reply)
            conn.close()
        except OSError:
            pass

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


class PortCheckTest(unittest.TestCase):
    def test_free_port_passes(self):
        s, port = free_listener()
        port = s.getsockname()[1]
        s.close()  # now free (SO_REUSEADDR allows immediate rebind on darwin)
        self.assertIsNone(doctor.check_port(port, "test"))

    def test_occupied_port_raises(self):
        s, port = free_listener()
        try:
            with self.assertRaises(doctor.DiagnosticFailure) as ctx:
                doctor.check_port(port, "test")
            self.assertEqual(ctx.exception.check_id, "port-in-use")
        finally:
            s.close()


class AmqpHandshakeTest(unittest.TestCase):
    def test_responsive_broker_ok(self):
        s, port = free_listener()
        try:
            responder(s, reply=b"AMQP\x00\x00\x09\x01")
            out = doctor.probe_amqp_handshake(timeout=2.0, port=port)
            self.assertTrue(out.startswith("HANDSHAKE_OK"), out)
        finally:
            s.close()

    def test_silent_listener_degraded(self):
        s, port = free_listener()
        try:
            responder(s, reply=None)  # accepts but never responds
            out = doctor.probe_amqp_handshake(timeout=0.5, port=port)
            self.assertTrue(out.startswith("HANDSHAKE_DEGRADED"), out)
        finally:
            s.close()

    def test_garbage_reply_degraded(self):
        s, port = free_listener()
        try:
            responder(s, reply=b"\x00\x00\x00\x00\xff\xff")
            out = doctor.probe_amqp_handshake(timeout=2.0, port=port)
            self.assertTrue(out.startswith("HANDSHAKE_DEGRADED"), out)
        finally:
            s.close()

    def test_closed_port_pass_free(self):
        s, port = free_listener()
        port = s.getsockname()[1]
        s.close()
        out = doctor.probe_amqp_handshake(timeout=2.0, port=port)
        self.assertTrue(out.startswith("PASS-FREE"), out)


if __name__ == "__main__":
    unittest.main()
