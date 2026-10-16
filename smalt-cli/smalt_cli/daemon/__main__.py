"""``python -m smalt_cli.daemon`` — start the loopback bridge."""

from smalt_cli.daemon.server import main

if __name__ == "__main__":
    raise SystemExit(main())
