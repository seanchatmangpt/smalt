"""``python -m smalt_cli.gateway`` — run the proxy on 127.0.0.1:18443.

SIGINT/SIGTERM trigger a clean shutdown of the HTTP server.
"""

from __future__ import annotations

import signal
import sys

from smalt_cli.gateway.interceptor import MutationInterceptor
from smalt_cli.gateway.proxy import GatewayProxy

DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 18443


def main(argv: list[str] | None = None) -> int:
    proxy = GatewayProxy(interceptor=MutationInterceptor())
    server = proxy.serve(bind=DEFAULT_BIND, port=DEFAULT_PORT)

    def _shutdown(signum: int, frame: object) -> None:
        # shutdown() must run off the serve_forever thread; a thread suffices.
        import threading

        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    print(
        f"smalt gateway: {DEFAULT_BIND}:{DEFAULT_PORT} -> {proxy.substrate}",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
