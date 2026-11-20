"""Private JSON-lines transport for the Windows desktop application."""

from concurrent.futures import ThreadPoolExecutor
from datetime import date
import json
from threading import Lock

from .market_data import BarQuery, UpstreamError


def serve(market_data, source, sink, catalog=None):
    write_lock = Lock()

    def respond(request):
        try:
            match request["operation"]:
                case "bars":
                    mode = request["mode"]
                    if mode not in {"cache_only", "prefer_cache", "refresh"}:
                        raise ValueError("invalid cache mode")
                    query = BarQuery(
                        request["symbol"], request["interval"],
                        date.fromisoformat(request["start"]), date.fromisoformat(request["end"]),
                    )
                    result = market_data.bars(query, mode=mode)
                case "preferences":
                    result = market_data.preferences()
                case "save_preferences":
                    market_data.save_preferences(request["value"])
                    result = None
                case "stock_names":
                    symbols = request["symbols"]
                    if not isinstance(symbols, list) or not all(isinstance(symbol, str) for symbol in symbols):
                        raise ValueError("expected an array of stock symbols")
                    result = catalog.for_symbols(symbols)
                case "stock_search":
                    result = catalog.search(request["keyword"])
                case _:
                    raise ValueError("unknown operation")
            response = {"result": result}
        except UpstreamError as exc:
            response = {"error": exc.code}
        except (KeyError, ValueError, TypeError) as exc:
            response = {"error": "invalid_request", "detail": str(exc)}
        except Exception:
            response = {"error": "gateway_error"}
        with write_lock:
            try:
                print(json.dumps({"id": request["id"], **response}), file=sink, flush=True)
            except OSError:
                pass

    workers = ThreadPoolExecutor(max_workers=2)
    try:
        for line in source:
            try:
                request = json.loads(line)
            except ValueError:
                continue
            if not isinstance(request, dict) or type(request.get("id")) is not int:
                continue
            if request.get("operation") == "stock_search" or (
                request.get("operation") == "bars" and request.get("mode") != "cache_only"
            ):
                workers.submit(respond, request)
            else:
                respond(request)
    finally:
        workers.shutdown(cancel_futures=True)
