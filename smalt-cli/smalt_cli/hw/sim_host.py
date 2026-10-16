"""Pty host for the Elixir virtual HIL device (Smalt.Hw.VirtualSerial).

Creates a raw-mode pty pair, spawns the Elixir device attached to the slave
(`mix run --no-start`), and exposes a SerialTransport-compatible transport
over the pty master — the Python-side contract is literally
SerialTransport.transact over a real tty, peer process is the real device.

CLI mode::

    python -m smalt_cli.hw.sim_host --gate2   # GATE2 witness via run_gates.py
    python -m smalt_cli.hw.sim_host --hold    # stay up as a device daemon
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import termios
import time

from .serial import MSG_ENROLL, SerialTransport, FrameDecoder

SMALT_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)

DEVICE_ENV = "SMALT_HW_PTY"

_ATTACH_STDIO = (
    'Smalt.Hw.VirtualSerial.start_link(stdio: true) '
    '|| raise("device start failed"); Process.sleep(:infinity)'
)

_MIX_ATTACH = "mix run --no-start -e " + _ATTACH_STDIO


def _elixir_cmd() -> list:
    """Direct `elixir --pa` launch over the prebuilt _build ebins — bypasses
    the shared mix build lock entirely (no compile step in the child).
    The pty is attached as the child's stdin/stdout (stdio device mode)."""
    import glob as _glob

    root = SMALT_ROOT
    pa = []
    for ebin in sorted(_glob.glob(os.path.join(root, "_build", "dev", "lib", "*", "ebin"))):
        pa += ["-pa", ebin]
    if not pa:
        return ["sh", "-c", "cd '%s' && %s" % (root, _MIX_ATTACH)]
    return ["elixir", "--no-halt"] + pa + ["-e", _ATTACH_STDIO]


def _set_raw(fd: int) -> None:
    """cfmakeraw equivalent (termios module has no cfmakeraw)."""
    a = termios.tcgetattr(fd)
    a[0] &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP
              | termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON)
    a[1] &= ~termios.OPOST
    a[2] &= ~(termios.CSIZE | termios.PARENB)
    a[2] |= termios.CS8
    a[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG
              | termios.IEXTEN)
    termios.tcsetattr(fd, termios.TCSANOW, a)


class SimHost:
    """One pty + one Elixir virtual device process."""

    def __init__(self, mix_cmd=None):
        self._mix_cmd = mix_cmd or _elixir_cmd()
        self.master_fd = None
        self.slave_fd = None
        self.proc = None
        self.tty_path = None

    def start(self, wait_ready_s: float = 180.0) -> str:
        """QEMU -serial pty pattern: the BEAM device gets the pty MASTER as
        its stdio; the host (pyserial) opens the slave path like real hw."""
        master, slave = os.openpty()
        _set_raw(slave)
        self.master_fd = master
        self.slave_fd = None
        self.tty_path = os.ttyname(slave)

        env = dict(os.environ)
        env[DEVICE_ENV] = self.tty_path
        self.proc = subprocess.Popen(
            self._mix_cmd, cwd=SMALT_ROOT, env=env,
            stdin=master, stdout=master, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        os.close(master)

        deadline = time.monotonic() + wait_ready_s
        last = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                out = self.proc.stderr.read().decode(errors="replace")
                raise RuntimeError("device died during boot: " + out[-2000:])
            t = SerialTransport(self.tty_path)
            env = t.transact({"type": MSG_ENROLL}, timeout_s=1.0)
            t.close()
            if env["status"] == "OK":
                return self.tty_path
            last = env
        raise RuntimeError("device not ready: last=%r" % (last,))

    def transport(self) -> SerialTransport:
        return SerialTransport(self.tty_path)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    self.proc.kill()
                except ProcessLookupError:
                    pass
        for fd in (self.master_fd, self.slave_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Elixir virtual HIL device host.")
    ap.add_argument("--gate2", action="store_true",
                    help="run GATE2 via run_gates.py against the sim device")
    ap.add_argument("--hold", action="store_true",
                    help="stay up as a device daemon")
    args = ap.parse_args(argv)

    host = SimHost()
    tty = host.start()
    print("SMALT_HW_PTY=" + tty, flush=True)
    os.environ[DEVICE_ENV] = tty

    if args.gate2:
        rc = subprocess.call(
            [sys.executable, os.path.join(SMALT_ROOT, "smalt-cli", "run_gates.py"),
             "--gate", "2"], cwd=SMALT_ROOT)
        host.stop()
        return rc

    if args.hold:
        try:
            signal.pause()
        except KeyboardInterrupt:
            pass
    host.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
