from concurrent.futures import ThreadPoolExecutor
from datetime import date
from io import StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from gateway.desktop import serve
from gateway.market_data import BarQuery, MarketData
from gateway.paper_trading import INITIAL_CASH, PaperTrading, fees


DAY = "2026-11-19"
NEXT = "2026-11-20"
SYMBOL = "sz000001"


class PaperTradingTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.market = MarketData(Path(self.directory.name) / "test.db")
        self.trading = PaperTrading(self.market.connect)
        self.account_id = self.trading.snapshot(DAY)["account_id"]
        self.counter = 0
        self.cache(DAY, "10.00")
        self.cache(NEXT, "12.00")

    def cache(self, day, price, symbol=SYMBOL, volume=1000):
        query = BarQuery(symbol, "1d", date.fromisoformat(day), date.fromisoformat(day))
        payload = dict(symbol=symbol, interval="1d", fetched_at=day + "T16:00:00+08:00",
                       bars=[dict(time=day, close=price, volume_shares=volume)])
        with self.market.connect() as db:
            db.execute("INSERT OR REPLACE INTO bar_snapshots VALUES (?, ?, ?)",
                       (query.cache_key, payload["fetched_at"], json.dumps(payload)))

    def order(self, **changes):
        self.counter += 1
        arguments = dict(account_id=self.account_id, request_id=f"order_{self.counter:016d}",
                         symbol=SYMBOL, side="buy", day=DAY, quantity=100, price=1000)
        return self.trading.order(**{**arguments, **changes})

    def test_buy_fees_balances_and_restart(self):
        account = self.order(quantity=1000)
        self.assertEqual(account["cash"], INITIAL_CASH - 1_000_500)
        self.assertEqual(account["profit"], -500)
        self.assertEqual(account["positions"][0]["cost"], 1_000_500)
        self.assertEqual(account["positions"][0]["available"], 0)
        restarted = PaperTrading(self.market.connect)
        self.assertEqual(restarted.snapshot(DAY), account)
        self.assertEqual(account["trades"][0]["price"], 1000)

    def test_partial_sell_uses_average_cost_and_preserves_ledger(self):
        self.order(quantity=200)
        self.order(quantity=200, day=NEXT, price=1200)
        account = self.order(side="sell", quantity=100, day=NEXT, price=1200)
        position = account["positions"][0]
        self.assertEqual(position["quantity"], 300)
        self.assertEqual(position["available"], 100)
        self.assertEqual(position["cost"], 330750)
        self.assertEqual(account["realized"], 9190)
        self.assertEqual(account["profit"], account["realized"] + position["unrealized"])
        self.assertEqual(account["trades"][0]["stamp"], 60)

    def test_full_liquidation_and_buy_again(self):
        self.order(quantity=200)
        account = self.order(side="sell", quantity=200, day=NEXT, price=1200)
        self.assertEqual(account["positions"], [])
        self.assertEqual(account["cash"], INITIAL_CASH + 38880)
        self.assertEqual(account["profit"], account["realized"])
        account = self.order(day=NEXT, price=1200)
        self.assertEqual(account["positions"][0]["available"], 0)

    def test_t_plus_one_and_short_sales_rollback(self):
        for before_buy in (True, False):
            if not before_buy:
                self.order()
            before = self.trading.snapshot(DAY)
            with self.assertRaisesRegex(ValueError, "可卖持仓不足"):
                self.order(side="sell")
            self.assertEqual(before, self.trading.snapshot(DAY))

    def test_oversell_and_insufficient_cash_do_not_mutate(self):
        self.order()
        before = self.trading.snapshot(NEXT)
        with self.assertRaisesRegex(ValueError, "可卖持仓不足"):
            self.order(side="sell", day=NEXT, price=1200, quantity=200)
        with self.assertRaisesRegex(ValueError, "可用资金不足"):
            self.order(quantity=100_000_000)
        self.assertEqual(before, self.trading.snapshot(NEXT))

    def test_fee_rounding(self):
        self.assertEqual(fees(1_668_334, "buy"), (501, 0))
        self.assertEqual(fees(101000, "sell"), (500, 51))

    def test_reject_invalid_quantity_price_symbol_and_request(self):
        for changes in (
            {"quantity": 0}, {"quantity": -100}, {"quantity": 10},
            {"quantity": 100.0}, {"quantity": True}, {"quantity": 100_000_100},
            {"price": True}, {"price": 10.0}, {"price": 0},
            {"symbol": "000001"}, {"symbol": "sh000001"},
            {"side": "short"}, {"request_id": "short"}, {"day": "2999-01-01"},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.order(**changes)
        self.assertEqual(self.trading.snapshot(DAY)["cash"], INITIAL_CASH)

    def test_cannot_trade_stale_or_missing_bar_or_suspended_day(self):
        for day in ("2026-11-18", "2026-11-21"):
            with self.assertRaisesRegex(ValueError, "没有可成交"):
                self.trading.quote(SYMBOL, day)
            with self.assertRaisesRegex(ValueError, "没有可成交"):
                self.order(day=day)
        self.cache(DAY, "10.00", volume=0)
        with self.assertRaisesRegex(ValueError, "没有可成交"):
            self.order()

    def test_quote_price_is_authoritative(self):
        self.assertEqual(self.trading.quote(SYMBOL, DAY)["price"], 1000)
        with self.assertRaisesRegex(ValueError, "收盘价已更新"):
            self.order(price=900)
        self.cache(DAY, "10.01")
        with self.assertRaisesRegex(ValueError, "收盘价已更新"):
            self.order()
        self.assertEqual(self.order(price=1001)["trades"][0]["price"], 1001)

    def test_no_future_price_leak_and_chronology_is_enforced(self):
        account = self.order()
        self.assertEqual(account["positions"][0]["price"], 1000)
        next_account = self.trading.snapshot(NEXT)
        self.assertEqual(next_account["positions"][0]["price"], 1200)
        self.order(day=NEXT, price=1200)
        with self.assertRaisesRegex(ValueError, "时间不能倒退"):
            self.order()
        self.assertEqual(self.trading.snapshot(DAY)["as_of"], NEXT)

    def test_stale_and_missing_valuations_are_explicit(self):
        self.order()
        account = self.trading.snapshot("2026-11-21")
        self.assertEqual(account["positions"][0]["price_day"], NEXT)
        with self.market.connect() as db:
            db.execute("DELETE FROM bar_snapshots")
        account = self.trading.snapshot(NEXT)
        position = account["positions"][0]
        self.assertIsNone(position["price"])
        self.assertEqual(position["market_value"], position["cost"])

    def test_same_request_is_idempotent_even_after_later_trades(self):
        identifier = "idempotent_request_01"
        self.order(request_id=identifier)
        self.order(day=NEXT, price=1200)
        account = self.order(request_id=identifier)
        self.assertEqual(account["trade_count"], 2)
        self.assertEqual(account["positions"][0]["quantity"], 200)
        with self.assertRaisesRegex(ValueError, "重复委托"):
            self.order(request_id=identifier, quantity=200)

    def test_concurrent_duplicate_and_spending_are_atomic(self):
        arguments = dict(account_id=self.account_id, request_id="concurrent_order_01", symbol=SYMBOL,
                         side="buy", day=DAY, quantity=5_000_000, price=1000)
        # First check identical concurrent requests execute exactly once.
        arguments["quantity"] = 50000
        with ThreadPoolExecutor(max_workers=4) as pool:
            accounts = list(pool.map(lambda _: self.trading.order(**arguments), range(4)))
        self.assertTrue(all(account["trade_count"] == 1 for account in accounts))
        # Each order is affordable alone, but only one can spend the remaining balance.
        def spend(index):
            try:
                self.trading.order(**{**arguments, "request_id": f"concurrent_spend_{index}", "quantity": 30000})
                return True
            except ValueError:
                return False
        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(spend, range(2))), [False, True])
        self.assertGreaterEqual(self.trading.snapshot(DAY)["cash"], 0)

    def test_reset_clears_ledger_and_invalidates_stale_orders(self):
        self.order()
        account = self.trading.reset(self.account_id, DAY)
        self.assertEqual(account["cash"], INITIAL_CASH)
        self.assertEqual(account["trade_count"], 0)
        self.assertEqual(account["positions"], [])
        self.assertNotEqual(account["account_id"], self.account_id)
        with self.assertRaisesRegex(ValueError, "已重置"):
            self.order()
        with self.assertRaisesRegex(ValueError, "已重置"):
            self.trading.reset(self.account_id, DAY)
        self.account_id = account["account_id"]
        self.order(day="2026-11-19")

    def test_desktop_operations_and_errors(self):
        requests = [
            dict(id=1, operation="paper_quote", symbol=SYMBOL, day=DAY),
            dict(id=2, operation="paper_order", account_id=self.account_id,
                 request_id="desktop_order_0001", symbol=SYMBOL, day=DAY, side="buy", quantity=100, price=1000),
            dict(id=3, operation="paper_order", account_id=self.account_id,
                 request_id="desktop_order_0002", symbol=SYMBOL, day=DAY, side="sell", quantity=100, price=1000),
            dict(id=4, operation="paper_account", day=NEXT),
            dict(id=5, operation="paper_reset", account_id=self.account_id, day=DAY),
        ]
        output = StringIO()
        serve(self.market, StringIO("\n".join(map(json.dumps, requests))), output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(responses[0]["result"]["price"], 1000)
        self.assertEqual(responses[1]["result"]["trade_count"], 1)
        self.assertEqual(responses[2]["error"], "invalid_request")
        self.assertIn("可卖持仓不足", responses[2]["detail"])
        self.assertEqual(responses[3]["result"]["positions"][0]["available"], 100)
        self.assertEqual(responses[4]["result"]["trade_count"], 0)


if __name__ == "__main__":
    unittest.main()
