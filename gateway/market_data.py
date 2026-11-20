"""Validated, unadjusted historical market data for the desktop client."""

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from time import sleep

from .symbols import parse_symbol


MARKET_TZ = timezone(timedelta(hours=8))
SOURCES = {"1d": ("tencent", "sina", "eastmoney"), "1m": ("sina", "eastmoney")}
CONTINUOUS_LABELS = {
    time(minute // 60, minute % 60)
    for start, end in ((571, 690), (781, 897))
    for minute in range(start, end + 1)
}


@dataclass(frozen=True)
class BarQuery:
    symbol: str
    interval: str
    start: date
    end: date

    def __post_init__(self):
        if parse_symbol(self.symbol) != self.symbol:
            raise ValueError("Expected a Shanghai, Shenzhen or Beijing A-share symbol")
        if self.interval not in SOURCES:
            raise ValueError("interval must be 1d or 1m")
        if self.start > self.end or (self.end - self.start).days > 366:
            raise ValueError("Select an ordered date range of at most 367 calendar days")
        if self.interval == "1m" and self.start != self.end:
            raise ValueError("Select a single date for minute data")

    @property
    def cache_key(self):
        return f"v1/{self.symbol}/{self.interval}/{self.start}/{self.end}"


class UpstreamError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def run_worker(source, query, *, direct=False):
    return worker_request([
        source, query.symbol,
        query.interval, query.start.isoformat(), query.end.isoformat(),
    ], direct=direct)


def worker_request(arguments, *, direct=False, timeout=25):
    command = [sys.executable, "-B", "-m", "gateway.worker", *arguments]
    if direct:
        command.append("--direct")
    try:
        result = subprocess.run(
            command, capture_output=True, encoding="utf-8", errors="replace", timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except subprocess.TimeoutExpired as exc:
        raise UpstreamError("timeout") from exc
    for line in reversed(result.stdout.splitlines()):
        if line.startswith("RESULT="):
            payload = json.loads(line.removeprefix("RESULT="))
            if "error" in payload:
                raise UpstreamError(payload["error"])
            return payload["rows"]
    raise UpstreamError("worker_failed")


def decimal_value(value):
    number = Decimal(str(value))
    if not number.is_finite() or number < 0:
        raise ValueError("invalid number")
    return number


def normalize(rows, query, fetched_at):
    bars = []
    observed = set()
    minute = query.interval == "1m"
    for raw in rows:
        timestamp = datetime.fromisoformat(str(raw["day" if minute else "date"]))
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=MARKET_TZ)
        timestamp = timestamp.astimezone(MARKET_TZ)
        day = timestamp.date()
        if not query.start <= day <= query.end:
            continue
        if not minute:
            timestamp = datetime.combine(day, time(15), MARKET_TZ)
        elif timestamp.second or timestamp.microsecond:
            raise ValueError("minute timestamps must align to the minute")
        if timestamp > fetched_at:
            continue
        if timestamp in observed:
            raise ValueError("duplicate bar timestamp")
        observed.add(timestamp)
        prices = {name: decimal_value(raw[name]) for name in ("open", "high", "low", "close")}
        if (prices["low"] <= 0 or prices["low"] != min(prices.values())
                or prices["high"] != max(prices.values())):
            raise ValueError("inconsistent OHLC")
        volume = decimal_value(raw["volume"])
        if volume != volume.to_integral_value():
            raise ValueError("volume must be a whole number of shares")
        amount = decimal_value(raw["amount"])
        bars.append({
            "time": timestamp.isoformat() if minute else day.isoformat(),
            **{name: format(value, "f") for name, value in prices.items()},
            "volume_shares": int(volume),
            "amount_cny": format(amount, "f"),
        })
    bars.sort(key=lambda bar: bar["time"])
    coverage = None
    if minute:
        labels = {timestamp.time() for timestamp in observed}
        missing = sorted(CONTINUOUS_LABELS - labels)
        coverage = {
            "continuous_minutes_expected": len(CONTINUOUS_LABELS),
            "continuous_minutes_missing": [label.isoformat(timespec="minutes") for label in missing],
            "has_1500_bar": time(15) in labels,
        }
    return bars, coverage


class MarketData:
    def __init__(self, database, worker=run_worker, backoff=sleep):
        self.database = Path(database)
        self.database.parent.mkdir(parents=True, exist_ok=True)
        self.worker = worker
        self.backoff = backoff
        with self.connect() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS bar_snapshots (
                    query_key TEXT PRIMARY KEY,
                    fetched_at TEXT NOT NULL,
                    payload TEXT NOT NULL
                )
            """)
            connection.execute("""
                CREATE TABLE IF NOT EXISTS desktop_preferences (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    payload TEXT NOT NULL
                )
            """)

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.database)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def cached_bars(self, query, reason=None):
        with self.connect() as connection:
            cached = connection.execute(
                "SELECT payload FROM bar_snapshots WHERE query_key = ?", (query.cache_key,)
            ).fetchone()
        if cached:
            return {**json.loads(cached[0]), "status": "cached", "reason": reason}
        return None

    def preferences(self):
        with self.connect() as connection:
            row = connection.execute(
                "SELECT payload FROM desktop_preferences WHERE id = 1"
            ).fetchone()
        return json.loads(row[0]) if row else {}

    def save_preferences(self, value):
        with self.connect() as connection:
            connection.execute("""
                INSERT INTO desktop_preferences VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
            """, (json.dumps(value, ensure_ascii=False),))

    def bars(self, query, mode="refresh"):
        if mode != "refresh":
            cached = self.cached_bars(query)
            if cached is not None or mode == "cache_only":
                return cached
        error = None
        empty = None
        sources = SOURCES[query.interval]
        if query.interval == "1d" and query.symbol.startswith("bj"):
            sources = ("eastmoney", "tencent", "sina")
        for source in sources:
            for attempt in range(2):
                try:
                    raw = self.worker(source, query)
                    fetched_at = datetime.now(MARKET_TZ)
                    bars, coverage = normalize(raw, query, fetched_at)
                except UpstreamError as exc:
                    error = exc.code
                    if error in {"timeout", "connection", "server_error"} and attempt == 0:
                        self.backoff(0.5)
                        continue
                    break
                except (KeyError, TypeError, ValueError, InvalidOperation):
                    error = "invalid_data"
                    break

                snapshot = {
                    "version": 1, "symbol": query.symbol, "interval": query.interval,
                    "start": query.start.isoformat(), "end": query.end.isoformat(),
                    "adjustment": "none", "source": source,
                    "fetched_at": fetched_at.isoformat(),
                    "status": "fresh" if bars else "empty",
                    "coverage": coverage, "bars": bars,
                }
                if bars:
                    with self.connect() as connection:
                        connection.execute("""
                            INSERT INTO bar_snapshots VALUES (?, ?, ?)
                            ON CONFLICT(query_key) DO UPDATE SET
                                fetched_at = excluded.fetched_at, payload = excluded.payload
                            WHERE excluded.fetched_at > bar_snapshots.fetched_at
                        """, (query.cache_key, snapshot["fetched_at"], json.dumps(snapshot)))
                    return snapshot
                empty = snapshot
                break

        cached = self.cached_bars(query, reason=error or "empty")
        if cached is not None:
            return cached
        if error:
            raise UpstreamError(error)
        return empty
