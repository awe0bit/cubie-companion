"""Production HTTP entrypoint, bound to loopback on every platform."""
import argparse
import json
import os
from pathlib import Path
import sys
# Installed source and offline-vendored dependency are root-owned.
sys.path[:0] = [str(Path(__file__).resolve().parent),
                str(Path(__file__).resolve().parent.parent / "vendor")]
from waitress import create_server
from server import App, ActionLedger


def build_server(config_path, state_path, port, host="127.0.0.1", pairing_path=None, telemetry=None):
    from pairing import PairingStore
    from host_bridge import FileCollector
    app = App(json.loads(Path(config_path).read_text(encoding="utf-8")),
              ledger=ActionLedger(str(state_path)),
              pairing=PairingStore(pairing_path) if pairing_path else None,
              observer=(lambda event: print(json.dumps(event), flush=True)) if os.environ.get('CORENEST_TRACE_REQUESTS') == '1' else None,
              collector=FileCollector(telemetry) if telemetry else None)
    server = create_server(app, host=host, port=port, threads=4,
        connection_limit=16, backlog=32, channel_timeout=15, asyncore_loop_timeout=0.1,
        max_request_body_size=1024, max_request_header_size=8192,
        expose_tracebacks=False, clear_untrusted_proxy_headers=True)
    return server, app


def main():
    parser = argparse.ArgumentParser()
    base = Path(os.environ.get("CREDENTIALS_DIRECTORY", "/etc/a7s-companion"))
    parser.add_argument("--config", type=Path, default=base / "config.json")
    parser.add_argument("--state", type=Path, default=Path("/var/lib/a7s-companion/actions.sqlite3"))
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--bind", choices=("127.0.0.1", "0.0.0.0"), default="127.0.0.1")
    parser.add_argument("--pairing", type=Path)
    parser.add_argument("--telemetry", type=Path)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("port must be between 1024 and 65535")
    try:
        os.umask(0o077)
        server, app = build_server(args.config, args.state, args.port, args.bind, args.pairing, args.telemetry)
    except (OSError, ValueError, TypeError, KeyError):
        raise SystemExit("Cannot start: check private configuration and state directory.")
    try:
        server.run()
    finally:
        server.close()
        app.ledger.connection.close()
        if app.pairing:
            app.pairing.db.close()


if __name__ == "__main__":
    main()
