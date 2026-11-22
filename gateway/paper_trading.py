"""Local historical-close simulator. All ledger amounts are integer CNY cents."""

from datetime import date, datetime
from decimal import Decimal, ROUND_HALF_UP
import json
import re
from uuid import uuid4

from .market_data import MARKET_TZ
from .symbols import parse_symbol


INITIAL_CASH = 100_000_000


def trading_day(value):
    day = date.fromisoformat(value)
    if day < date(1991, 1, 1) or day > datetime.now(MARKET_TZ).date():
        raise ValueError("请选择 1991 年至今天之间的模拟日期")
    return day.isoformat()


def fees(amount, side):
    # Deliberately simplified simulation assumptions, not a broker fee schedule.
    commission = max(500, (amount * 3 + 5000) // 10000)
    stamp = (amount * 5 + 5000) // 10000 if side == "sell" else 0
    return commission, stamp


class PaperTrading:
    def __init__(self, connect):
        self.connect = connect
        with connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS paper_account (
                id INTEGER PRIMARY KEY CHECK (id = 1), account_id TEXT NOT NULL,
                cash INTEGER NOT NULL CHECK (cash >= 0),
                realized INTEGER NOT NULL DEFAULT 0, last_day TEXT
            )""")
            db.execute("""CREATE TABLE IF NOT EXISTS paper_positions (
                symbol TEXT PRIMARY KEY, quantity INTEGER NOT NULL CHECK (quantity > 0),
                cost INTEGER NOT NULL CHECK (cost >= 0)
            )""")
            db.execute("""CREATE TABLE IF NOT EXISTS paper_lots (
                id INTEGER PRIMARY KEY, symbol TEXT NOT NULL, day TEXT NOT NULL,
                quantity INTEGER NOT NULL CHECK (quantity >= 0)
            )""")
            db.execute("""CREATE TABLE IF NOT EXISTS paper_trades (
                id INTEGER PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
                fingerprint TEXT NOT NULL, symbol TEXT NOT NULL, side TEXT NOT NULL,
                day TEXT NOT NULL, quantity INTEGER NOT NULL, price INTEGER NOT NULL,
                amount INTEGER NOT NULL, commission INTEGER NOT NULL,
                stamp INTEGER NOT NULL, realized INTEGER NOT NULL, created_at TEXT NOT NULL
            )""")
            db.execute("INSERT OR IGNORE INTO paper_account (id, account_id, cash) VALUES (1, ?, ?)",
                       (uuid4().hex, INITIAL_CASH))

    def _prices(self, db, day, symbols):
        """Use only completed daily bars at or before the simulation date."""
        prices = {}
        if not symbols:
            return prices
        for (payload,) in db.execute("SELECT payload FROM bar_snapshots"):
            snapshot = json.loads(payload)
            symbol = snapshot["symbol"]
            if symbol not in symbols or snapshot["interval"] != "1d":
                continue
            for bar in snapshot["bars"]:
                bar_day = bar["time"]
                if bar_day > day or bar["volume_shares"] <= 0:
                    continue
                rank = (bar_day, snapshot["fetched_at"])
                if symbol in prices and rank <= prices[symbol]["rank"]:
                    continue
                value = Decimal(bar["close"]) * 100
                if not value.is_finite() or value <= 0:
                    continue
                # A-share prices use cents; reject non-cent data rather than silently rounding.
                if value != value.to_integral_value():
                    continue
                prices[symbol] = {"price": int(value), "day": bar_day, "rank": rank}
        return prices

    def quote(self, symbol, day):
        day = trading_day(day)
        if not isinstance(symbol, str) or parse_symbol(symbol) != symbol:
            raise ValueError("请输入有效的沪深北 A 股证券代码")
        with self.connect() as db:
            quote = self._prices(db, day, {symbol}).get(symbol)
        if quote is None or quote["day"] != day:
            raise ValueError("所选日期没有可成交的日 K 行情，请先获取行情；休市或停牌日期不可下单")
        return {"symbol": symbol, "day": day, "price": quote["price"]}

    def snapshot(self, day):
        day = trading_day(day)
        with self.connect() as db:
            db.execute("BEGIN")
            return self._snapshot(db, day)

    def _snapshot(self, db, day):
        account_id, cash, realized, last_day = db.execute(
            "SELECT account_id, cash, realized, last_day FROM paper_account WHERE id = 1"
        ).fetchone()
        as_of = max(day, last_day or day)
        rows = db.execute("SELECT symbol, quantity, cost FROM paper_positions ORDER BY symbol").fetchall()
        prices = self._prices(db, as_of, {row[0] for row in rows})
        positions = []
        for symbol, quantity, cost in rows:
            quote = prices.get(symbol)
            # Missing valuations are explicitly marked and carried at cost.
            value = quote["price"] * quantity if quote else cost
            available = db.execute(
                "SELECT COALESCE(SUM(quantity), 0) FROM paper_lots WHERE symbol = ? AND day < ?",
                (symbol, as_of),
            ).fetchone()[0]
            positions.append(dict(symbol=symbol, quantity=quantity, available=available, cost=cost,
                                  price=quote["price"] if quote else None,
                                  price_day=quote["day"] if quote else None,
                                  market_value=value, unrealized=value - cost))
        market_value = sum(item["market_value"] for item in positions)
        columns = ("id", "symbol", "side", "day", "quantity", "price", "amount", "commission",
                   "stamp", "realized", "created_at")
        trades = [dict(zip(columns, row)) for row in db.execute(
            f"SELECT {', '.join(columns)} FROM paper_trades ORDER BY id DESC LIMIT 200"
        )]
        return dict(account_id=account_id, initial_cash=INITIAL_CASH, cash=cash,
                    realized=realized, last_day=last_day, as_of=as_of, market_value=market_value,
                    equity=cash + market_value, profit=cash + market_value - INITIAL_CASH,
                    positions=positions, trades=trades,
                    trade_count=db.execute("SELECT COUNT(*) FROM paper_trades").fetchone()[0])

    def order(self, *, account_id, request_id, symbol, side, day, quantity, price):
        day = trading_day(day)
        if not isinstance(symbol, str) or parse_symbol(symbol) != symbol:
            raise ValueError("请输入有效的沪深北 A 股证券代码")
        if side not in ("buy", "sell"):
            raise ValueError("无效的买卖方向")
        if type(quantity) is not int or quantity <= 0 or quantity > 100_000_000 or quantity % 100:
            raise ValueError("模拟买卖数量须为 100 股的整数倍，且不超过 1 亿股")
        if type(price) is not int or price <= 0:
            raise ValueError("无效的成交价格")
        if not isinstance(request_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,80}", request_id):
            raise ValueError("无效的委托标识")
        fingerprint = json.dumps([account_id, symbol, side, day, quantity, price])
        with self.connect() as db:
            # Serialize balance checks and ledger writes, including across processes.
            db.execute("BEGIN IMMEDIATE")
            current_id, cash, last_day = db.execute(
                "SELECT account_id, cash, last_day FROM paper_account WHERE id = 1"
            ).fetchone()
            if account_id != current_id:
                raise ValueError("模拟账户已重置，请刷新账户后重新下单")
            previous = db.execute("SELECT fingerprint FROM paper_trades WHERE request_id = ?",
                                  (request_id,)).fetchone()
            if previous:
                if previous[0] != fingerprint:
                    raise ValueError("重复委托的内容不一致，请重新下单")
                return self._snapshot(db, day)
            if last_day and day < last_day:
                raise ValueError(f"模拟时间不能倒退，请选择 {last_day} 或之后的日期")
            quote = self._prices(db, day, {symbol}).get(symbol)
            if quote is None or quote["day"] != day:
                raise ValueError("所选日期没有可成交的日 K 行情，请先获取行情")
            if price != quote["price"]:
                raise ValueError("缓存收盘价已更新，请刷新报价后重新下单")
            amount = price * quantity
            commission, stamp = fees(amount, side)
            position = db.execute("SELECT quantity, cost FROM paper_positions WHERE symbol = ?",
                                  (symbol,)).fetchone()
            held, cost = position or (0, 0)
            realized = 0
            if side == "buy":
                debit = amount + commission
                if debit > cash:
                    raise ValueError("可用资金不足（买入需要包含模拟佣金）")
                cash -= debit
                db.execute("""INSERT INTO paper_positions VALUES (?, ?, ?)
                    ON CONFLICT(symbol) DO UPDATE SET quantity = quantity + excluded.quantity,
                    cost = cost + excluded.cost""", (symbol, quantity, debit))
                db.execute("INSERT INTO paper_lots (symbol, day, quantity) VALUES (?, ?, ?)",
                           (symbol, day, quantity))
            else:
                lots = db.execute("""SELECT id, quantity FROM paper_lots
                    WHERE symbol = ? AND day < ? AND quantity > 0 ORDER BY day, id""",
                                  (symbol, day)).fetchall()
                if quantity > sum(lot[1] for lot in lots):
                    raise ValueError("可卖持仓不足；本模拟账户实行 T+1，当日买入次日才可卖出")
                remaining = quantity
                for lot_id, count in lots:
                    taken = min(remaining, count)
                    db.execute("UPDATE paper_lots SET quantity = quantity - ? WHERE id = ?", (taken, lot_id))
                    remaining -= taken
                    if not remaining:
                        break
                released_cost = int((Decimal(cost) * quantity / held).quantize(Decimal(1), rounding=ROUND_HALF_UP))
                proceeds = amount - commission - stamp
                if cash + proceeds < 0:
                    raise ValueError("可用资金不足以支付模拟卖出费用")
                cash += proceeds
                realized = proceeds - released_cost
                if quantity == held:
                    db.execute("DELETE FROM paper_positions WHERE symbol = ?", (symbol,))
                else:
                    db.execute("UPDATE paper_positions SET quantity = ?, cost = ? WHERE symbol = ?",
                               (held - quantity, cost - released_cost, symbol))
                db.execute("DELETE FROM paper_lots WHERE quantity = 0")
            db.execute("UPDATE paper_account SET cash = ?, realized = realized + ?, last_day = ? WHERE id = 1",
                       (cash, realized, day))
            db.execute("""INSERT INTO paper_trades
                (request_id, fingerprint, symbol, side, day, quantity, price, amount, commission, stamp, realized, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                       (request_id, fingerprint, symbol, side, day, quantity, price, amount, commission,
                        stamp, realized, datetime.now(MARKET_TZ).isoformat()))
            return self._snapshot(db, day)

    def reset(self, account_id, day):
        day = trading_day(day)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT account_id FROM paper_account WHERE id = 1").fetchone()[0] != account_id:
                raise ValueError("模拟账户已重置，请刷新账户")
            for table in ("paper_trades", "paper_lots", "paper_positions"):
                db.execute(f"DELETE FROM {table}")
            db.execute("UPDATE paper_account SET account_id = ?, cash = ?, realized = 0, last_day = NULL WHERE id = 1",
                       (uuid4().hex, INITIAL_CASH))
            return self._snapshot(db, day)
