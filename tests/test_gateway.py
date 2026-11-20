from datetime import date, datetime
from io import StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from gateway.__main__ import migrate_cache, query_from_url
from gateway.catalog import StockCatalog
from gateway.desktop import serve
from gateway.market_data import BarQuery, MARKET_TZ, MarketData, UpstreamError, normalize
from gateway.symbols import parse_symbol


DAY = date(2026, 11, 20)
MINUTE = BarQuery("sz000001", "1m", DAY, DAY)
DAILY = BarQuery("sz000001", "1d", DAY, DAY)
AFTER_CLOSE = datetime(2026, 11, 20, 16, tzinfo=MARKET_TZ)
ROW = {
    "day": "2026-11-20 09:31:00", "date": "2026-11-20",
    "open": "12.010", "high": "12.30", "low": "12.00", "close": "12.20",
    "volume": "100", "amount": "1220.0001",
}


class GatewayTests(unittest.TestCase):
    def test_normalization_preserves_precision_and_reports_gaps(self):
        bars, coverage = normalize([ROW], MINUTE, AFTER_CLOSE)
        self.assertEqual(bars[0]["open"], "12.010")
        self.assertEqual(bars[0]["volume_shares"], 100)
        self.assertEqual(bars[0]["amount_cny"], "1220.0001")
        self.assertEqual(bars[0]["time"], "2026-11-20T09:31:00+08:00")
        self.assertEqual(len(coverage["continuous_minutes_missing"]), 236)
        self.assertFalse(coverage["has_1500_bar"])

    def test_future_or_unclosed_bars_are_excluded(self):
        before_open = datetime(2026, 11, 20, 9, 30, tzinfo=MARKET_TZ)
        for query in (MINUTE, DAILY):
            with self.subTest(interval=query.interval):
                self.assertEqual(normalize([ROW], query, before_open)[0], [])

    def test_reject_duplicate_bars_and_invalid_ohlc(self):
        for rows in ([ROW, ROW], [{**ROW, "high": "12.11"}]):
            with self.assertRaises(ValueError):
                normalize(rows, MINUTE, AFTER_CLOSE)

    def test_transient_failure_and_single_source_fallback(self):
        calls = []
        delays = []

        def worker(source, query):
            calls.append(source)
            if source == "tencent":
                raise UpstreamError("timeout")
            return [ROW]

        with TemporaryDirectory() as path:
            service = MarketData(Path(path) / "market.db", worker=worker, backoff=delays.append)
            result = service.bars(DAILY)
        self.assertEqual(calls, ["tencent", "tencent", "sina"])
        self.assertEqual(delays, [0.5])
        self.assertEqual(result["source"], "sina")

    def test_rate_limit_falls_back_to_persisted_cache(self):
        calls = []

        def throttled(source, query):
            calls.append(source)
            raise UpstreamError("rate_limited")

        with TemporaryDirectory() as path:
            database = Path(path) / "market.db"
            first = MarketData(database, worker=lambda *_: [ROW]).bars(MINUTE)
            restarted = MarketData(database, worker=throttled)
            cached = restarted.bars(MINUTE)
            self.assertEqual(calls, ["sina", "eastmoney"])
            self.assertEqual(cached, {**first, "status": "cached", "reason": "rate_limited"})
            with self.assertRaisesRegex(UpstreamError, "rate_limited"):
                restarted.bars(BarQuery("sh600519", "1m", DAY, DAY))

    def test_empty_source_and_bad_query(self):
        with TemporaryDirectory() as path:
            service = MarketData(Path(path) / "market.db", worker=lambda *_: [])
            self.assertEqual(service.bars(MINUTE)["status"], "empty")
        with self.assertRaises(ValueError):
            query_from_url("symbol=sz000001&symbol=sh600519")

    def test_growth_market_codes_and_cache_first_reopening(self):
        query = BarQuery("sz300033", "1m", DAY, DAY)
        BarQuery("sh688981", "1d", DAY, DAY)

        def offline(*_):
            self.fail("reading a persisted snapshot must not call the upstream worker")

        with TemporaryDirectory() as path:
            path = Path(path)
            old_db = path / "old.db"
            first = MarketData(old_db, worker=lambda *_: [ROW]).bars(query)
            new_db = path / "desktop" / "market.db"
            migrate_cache(old_db, new_db)
            restarted = MarketData(new_db, worker=offline)
            for mode in ("cache_only", "prefer_cache"):
                self.assertEqual(
                    restarted.bars(query, mode=mode),
                    {**first, "status": "cached", "reason": None},
                )
            self.assertIsNone(restarted.bars(DAILY, mode="cache_only"))

    def test_private_transport_preserves_preferences_and_cache_miss(self):
        requests = [
            {"id": 1, "operation": "save_preferences", "value": {"selected": "sz300033"}},
            {"id": 2, "operation": "preferences"},
            {"id": 3, "operation": "bars", "mode": "cache_only", "symbol": "sz300033",
             "interval": "1m", "start": DAY.isoformat(), "end": DAY.isoformat()},
        ]
        incoming = StringIO("\n".join(map(json.dumps, requests)))
        outgoing = StringIO()
        with TemporaryDirectory() as path:
            database = Path(path) / "market.db"
            serve(MarketData(database), incoming, outgoing)
            self.assertEqual(MarketData(database).preferences(), {"selected": "sz300033"})
        self.assertEqual(
            [json.loads(line) for line in outgoing.getvalue().splitlines()],
            [{"id": 1, "result": None}, {"id": 2, "result": {"selected": "sz300033"}},
             {"id": 3, "result": None}],
        )

    def test_on_demand_directory_and_board_routing(self):
        for raw, expected in (
            ("688981.SH", "sh688981"),
            ("302132", "sz302132"),
            ("920445.BJ", "bj920445"),
            ("bj831445", "bj831445"),
        ):
            self.assertEqual(parse_symbol(raw), expected)
            BarQuery(expected, "1d", DAY, DAY)
        self.assertIsNone(parse_symbol("920445.SZ"))
        calls = []

        def worker(args, **_):
            calls.append(tuple(args))
            if args == ["name", "sz302132"]:
                return [{"symbol": "sz302132", "name": "动态名称"}]
            if args == ["catalog", "bj"]:
                return [{"symbol": "bj920445", "name": "目录股票"}]
            raise UpstreamError("timeout")

        with TemporaryDirectory() as path:
            market = MarketData(Path(path) / "test.db")
            catalog = StockCatalog(market.connect, worker)
            self.assertEqual(catalog.search("302132")["matches"][0]["name"], "动态名称")
            first = catalog.search("目录")
            self.assertEqual(first["matches"], [{"symbol": "bj920445", "name": "目录股票"}])
            self.assertIn("sh_main", first["unavailable"])
            restarted = StockCatalog(market.connect, worker)
            self.assertEqual(restarted.search("302132")["matches"][0]["name"], "动态名称")
            self.assertEqual(calls.count(("name", "sz302132")), 1)


if __name__ == "__main__":
    unittest.main()
