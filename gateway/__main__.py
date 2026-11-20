"""Run the MikuStock gateway on Windows loopback."""

import argparse
from contextlib import closing
from datetime import date
from functools import partial
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
from urllib.parse import parse_qs, urlsplit

from .catalog import StockCatalog
from .market_data import BarQuery, MarketData, UpstreamError, run_worker, worker_request
from .desktop import serve


def query_from_url(raw_query):
    params = parse_qs(raw_query, keep_blank_values=True, max_num_fields=4)
    if set(params) != {"symbol", "interval", "start", "end"} or any(
        len(values) != 1 for values in params.values()
    ):
        raise ValueError("Supply one value each for symbol, interval, start, and end")
    return BarQuery(
        params["symbol"][0], params["interval"][0],
        date.fromisoformat(params["start"][0]), date.fromisoformat(params["end"][0]),
    )


def handler_for(market_data):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(5)
            super().setup()

        def do_GET(self):
            host = self.headers.get("Host")
            if host != f"127.0.0.1:{self.server.server_port}":
                self.send_json(400, {"error": "invalid_host"})
                return
            try:
                url = urlsplit(self.path)
            except ValueError:
                self.send_json(400, {"error": "invalid_url"})
                return
            if url.path == "/health":
                self.send_json(200, {"version": 1, "status": "ok"})
            elif url.path == "/v1/bars":
                try:
                    query = query_from_url(url.query)
                except ValueError as exc:
                    self.send_json(400, {"error": "invalid_query", "detail": str(exc)})
                    return
                try:
                    response = market_data.bars(query)
                except UpstreamError as exc:
                    self.send_json(503, {"error": exc.code})
                    return
                self.send_json(200, response)
            else:
                self.send_json(404, {"error": "not_found"})

        def send_json(self, status, payload):
            content = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

    return Handler


def migrate_cache(source, target):
    if not source or not source.is_file() or target.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=target.parent) as directory:
        backup = Path(directory) / "market.sqlite3"
        with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as legacy:
            with closing(sqlite3.connect(backup)) as destination:
                legacy.backup(destination)
        try:
            # On Windows rename fails if the target already exists.
            (os.rename if os.name == "nt" else os.link)(backup, target)
        except FileExistsError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--db", type=Path, default=Path("data/market.sqlite3"))
    parser.add_argument("--legacy-db", type=Path)
    parser.add_argument("--stdio", action="store_true")
    parser.add_argument("--direct", action="store_true", help="Ignore proxy settings in AKShare worker requests")
    args = parser.parse_args()
    migrate_cache(args.legacy_db, args.db)
    market_data = MarketData(args.db, worker=partial(run_worker, direct=args.direct))
    if args.stdio:
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
        catalog = StockCatalog(market_data.connect, partial(worker_request, direct=args.direct))
        serve(market_data, sys.stdin, sys.stdout, catalog)
        return
    with HTTPServer(("127.0.0.1", args.port), handler_for(market_data)) as server:
        print(f"MikuStock gateway: http://127.0.0.1:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
