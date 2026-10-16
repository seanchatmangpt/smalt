"""`smalt-cli hw` subcommands: discover / enroll / sign / flash."""

from __future__ import annotations

import sys
from typing import Optional

try:
    import typer
except ImportError:  # allow direct invocation without typer
    typer = None

from .attest import attest
from .flasher import flash_avm
from .serial import (
    MSG_CAPABILITIES,
    MSG_ENROLL,
    MSG_SIGN_CHALLENGE,
    Capabilities,
    DeviceError,
    SerialTransport,
    decode_message,
    encode_message,
    FrameDecoder,
)

if typer is not None:
    hw_app = typer.Typer(help="AtomVM hardware bridge (USB-CDC)")
else:
    hw_app = None


def _emit(obj) -> None:
    import json
    import dataclasses

    if dataclasses.is_dataclass(obj):
        print(json.dumps(dataclasses.asdict(obj), indent=2))
    else:
        print(json.dumps(obj, indent=2, default=str))


def _open_port(port: str) -> Optional[SerialTransport]:
    try:
        return SerialTransport(port)
    except Exception as exc:  # noqa: BLE001
        print(f"IO_ERROR: {exc}", file=sys.stderr)
        return None


def cmd_discover() -> int:
    ports = SerialTransport.discover()
    import json

    print(json.dumps(ports, indent=2))
    return 0


def cmd_enroll(port: str) -> int:
    t = _open_port(port)
    if t is None:
        return 1
    try:
        env = t.transact({"type": MSG_ENROLL})
        _emit(env["value"] if env["status"] == "OK" else env)
        return 0 if env["status"] == "OK" else 1
    finally:
        t.close()


def cmd_sign(port: str, digest: Optional[str]) -> int:
    t = _open_port(port)
    if t is None:
        return 1
    try:
        if digest is None:
            result = attest(t)
            _emit(result)
            return 0 if result["status"] in ("OK", "REFUSED") else 1
        env = t.transact({"type": MSG_SIGN_CHALLENGE, "sha256Digest": digest})
        _emit(env["value"] if env["status"] == "OK" else env)
        return 0 if env["status"] == "OK" else 1
    finally:
        t.close()


def cmd_flash(port: str, avm_path: str) -> int:
    t = _open_port(port)
    if t is None:
        return 1
    try:
        env = flash_avm(t, avm_path)
        _emit(env)
        return 0 if env["status"] == "OK" else 1
    finally:
        t.close()


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: smalt-cli hw {discover|enroll|sign|flash}")
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "discover":
        return cmd_discover()
    if cmd == "enroll":
        return cmd_enroll(rest[0])
    if cmd == "sign":
        return cmd_sign(rest[0], rest[1] if len(rest) > 1 else None)
    if cmd == "flash":
        return cmd_flash(rest[0], rest[1])
    print(f"unknown hw command: {cmd}", file=sys.stderr)
    return 2


if typer is not None and hw_app is not None:

    @hw_app.command("discover")
    def _discover_cmd() -> None:
        raise typer.Exit(cmd_discover())

    @hw_app.command("enroll")
    def _enroll_cmd(port: str) -> None:
        raise typer.Exit(cmd_enroll(port))

    @hw_app.command("sign")
    def _sign_cmd(
        port: Optional[str] = typer.Argument(None),
        device: Optional[str] = typer.Option(None, "--device"),
        digest: Optional[str] = None,
    ) -> None:
        # gates.py:288 invokes `hw sign --device <PORT>`; accept both the
        # positional port and the --device alias (S-5 alignment fix).
        actual = device or port
        if not actual:
            print("hw sign: port required (positional or --device)", file=sys.stderr)
            raise typer.Exit(2)
        raise typer.Exit(cmd_sign(actual, digest))

    @hw_app.command("flash")
    def _flash_cmd(port: str, avm_path: str) -> None:
        raise typer.Exit(cmd_flash(port, avm_path))


if __name__ == "__main__":  # python -m smalt_cli.hw.cli ...
    raise SystemExit(main())
