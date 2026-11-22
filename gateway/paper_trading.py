"""Local historical-close simulator. All ledger amounts are integer CNY cents."""

from datetime import date, datetime
from decimal import Decimal, ROUND_HALF_UP
import json
import re
from uuid import uuid4

from .market_data import MARKET_TZ
from .symbols import parse_symbol


INITIAL_CASH = 100_000_000
MAX_PRICE = 100_000_000


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
            db.execute("BEGIN IMMEDIATE")
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
            if "event_day" not in {row[1] for row in db.execute("PRAGMA table_info(paper_account)")}:
                db.execute("ALTER TABLE paper_account ADD COLUMN event_day TEXT")
                db.execute("UPDATE paper_account SET event_day = last_day")
            db.execute("""CREATE TABLE IF NOT EXISTS paper_orders (
                id INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT UNIQUE NOT NULL,
                fingerprint TEXT NOT NULL, symbol TEXT NOT NULL, side TEXT NOT NULL,
                day TEXT NOT NULL, quantity INTEGER NOT NULL, limit_price INTEGER NOT NULL,
                reserved_cash INTEGER NOT NULL CHECK (reserved_cash >= 0),
                status TEXT NOT NULL CHECK (status IN ('pending', 'filled', 'cancelled')),
                checked_day TEXT, check_note TEXT, filled_day TEXT, filled_price INTEGER,
                cancelled_day TEXT, created_at TEXT NOT NULL
            )""")
            db.execute("CREATE INDEX IF NOT EXISTS paper_pending_orders ON paper_orders(status, symbol)")
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
        account_id, cash, realized, last_day, event_day = db.execute(
            "SELECT account_id, cash, realized, last_day, event_day FROM paper_account WHERE id = 1"
        ).fetchone()
        as_of = max(day, event_day or last_day or day)
        frozen_cash = self._frozen_cash(db)
        rows = db.execute("SELECT symbol, quantity, cost FROM paper_positions ORDER BY symbol").fetchall()
        prices = self._prices(db, as_of, {row[0] for row in rows})
        positions = []
        for symbol, quantity, cost in rows:
            quote = prices.get(symbol)
            # Missing valuations are explicitly marked and carried at cost.
            value = quote["price"] * quantity if quote else cost
            frozen = self._frozen_shares(db, symbol)
            available = self._sellable(db, symbol, as_of) - frozen
            positions.append(dict(symbol=symbol, quantity=quantity, available=available, frozen=frozen, cost=cost,
                                  price=quote["price"] if quote else None,
                                  price_day=quote["day"] if quote else None,
                                  market_value=value, unrealized=value - cost))
        market_value = sum(item["market_value"] for item in positions)
        columns = ("id", "symbol", "side", "day", "quantity", "price", "amount", "commission",
                   "stamp", "realized", "created_at")
        trades = [dict(zip(columns, row)) for row in db.execute(
            f"SELECT {', '.join(columns)} FROM paper_trades ORDER BY id DESC LIMIT 200"
        )]
        order_columns = ("id", "symbol", "side", "day", "quantity", "limit_price", "reserved_cash",
                         "status", "checked_day", "check_note", "filled_day", "filled_price", "cancelled_day")
        # Always include every pending order, even when there are many terminal records.
        orders = [dict(zip(order_columns, row)) for row in db.execute(f"""
            SELECT {', '.join(order_columns)} FROM paper_orders WHERE status = 'pending'
            UNION ALL SELECT {', '.join(order_columns)} FROM (
                SELECT * FROM paper_orders WHERE status != 'pending' ORDER BY id DESC LIMIT 200
            ) ORDER BY id DESC
        """)]
        return dict(account_id=account_id, initial_cash=INITIAL_CASH, cash=cash,
                    available_cash=cash - frozen_cash, frozen_cash=frozen_cash, event_day=event_day,
                    realized=realized, last_day=last_day, as_of=as_of, market_value=market_value,
                    equity=cash + market_value, profit=cash + market_value - INITIAL_CASH,
                    positions=positions, trades=trades, orders=orders,
                    order_count=db.execute("SELECT COUNT(*) FROM paper_orders").fetchone()[0],
                    pending_count=db.execute("SELECT COUNT(*) FROM paper_orders WHERE status = 'pending'").fetchone()[0],
                    trade_count=db.execute("SELECT COUNT(*) FROM paper_trades").fetchone()[0])

    @staticmethod
    def _frozen_cash(db):
        return db.execute("SELECT COALESCE(SUM(reserved_cash), 0) FROM paper_orders WHERE status = 'pending'").fetchone()[0]

    @staticmethod
    def _frozen_shares(db, symbol):
        return db.execute("""SELECT COALESCE(SUM(quantity), 0) FROM paper_orders
            WHERE status = 'pending' AND side = 'sell' AND symbol = ?""", (symbol,)).fetchone()[0]

    @staticmethod
    def _sellable(db, symbol, day):
        return db.execute("SELECT COALESCE(SUM(quantity), 0) FROM paper_lots WHERE symbol = ? AND day < ?",
                          (symbol, day)).fetchone()[0]

    @staticmethod
    def _validate_order(symbol, side, quantity, price, request_id):
        if not isinstance(symbol, str) or parse_symbol(symbol) != symbol:
            raise ValueError("请输入有效的沪深北 A 股证券代码")
        if side not in ("buy", "sell"):
            raise ValueError("无效的买卖方向")
        if type(quantity) is not int or quantity <= 0 or quantity > 100_000_000 or quantity % 100:
            raise ValueError("模拟买卖数量须为 100 股的整数倍，且不超过 1 亿股")
        if type(price) is not int or not 0 < price <= MAX_PRICE:
            raise ValueError("价格须大于 0，且不超过 1,000,000.00 元")
        if not isinstance(request_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,80}", request_id):
            raise ValueError("无效的委托标识")

    @staticmethod
    def _check_account(db, account_id, day=None):
        current_id, cash, event_day = db.execute(
            "SELECT account_id, cash, event_day FROM paper_account WHERE id = 1"
        ).fetchone()
        if account_id != current_id:
            raise ValueError("模拟账户已重置，请刷新账户后重新下单")
        if day is not None and event_day and day < event_day:
            raise ValueError(f"模拟时间不能倒退，请选择 {event_day} 或之后的日期")
        return cash

    def place_limit(self, *, account_id, request_id, symbol, side, day, quantity, limit_price):
        day = trading_day(day)
        self._validate_order(symbol, side, quantity, limit_price, request_id)
        fingerprint = json.dumps(["limit", account_id, symbol, side, day, quantity, limit_price])
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._check_account(db, account_id)
            previous = db.execute("SELECT fingerprint FROM paper_orders WHERE request_id = ?", (request_id,)).fetchone()
            if previous:
                if previous[0] != fingerprint:
                    raise ValueError("重复委托的内容不一致，请重新下单")
                return self._snapshot(db, day)
            if db.execute("SELECT 1 FROM paper_trades WHERE request_id = ?", (request_id,)).fetchone():
                raise ValueError("委托标识已被使用，请重新下单")
            cash = self._check_account(db, account_id, day)
            quote = self._prices(db, day, {symbol}).get(symbol)
            if quote is None or quote["day"] != day:
                raise ValueError("所选日期没有可成交的日 K 行情，请先获取行情")
            amount = limit_price * quantity
            commission, stamp = fees(amount, side)
            reserved_cash = amount + commission if side == "buy" else max(0, commission + stamp - amount)
            if reserved_cash > cash - self._frozen_cash(db):
                raise ValueError("可用资金不足（挂单需要冻结含模拟费用的资金）")
            if side == "sell" and quantity > self._sellable(db, symbol, day) - self._frozen_shares(db, symbol):
                raise ValueError("可卖持仓不足；请检查 T+1 限制及其他挂单冻结的数量")
            db.execute("""INSERT INTO paper_orders
                (request_id, fingerprint, symbol, side, day, quantity, limit_price, reserved_cash, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)""",
                       (request_id, fingerprint, symbol, side, day, quantity, limit_price,
                        reserved_cash, datetime.now(MARKET_TZ).isoformat()))
            db.execute("UPDATE paper_account SET event_day = ? WHERE id = 1", (day,))
            return self._snapshot(db, day)

    def cancel(self, *, account_id, order_id, day):
        day = trading_day(day)
        if type(order_id) is not int or order_id <= 0:
            raise ValueError("无效的委托编号")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._check_account(db, account_id)
            row = db.execute("SELECT status FROM paper_orders WHERE id = ?", (order_id,)).fetchone()
            if row is None:
                raise ValueError("未找到该委托，请刷新账户")
            if row[0] == "cancelled":
                return self._snapshot(db, day)
            if row[0] != "pending":
                raise ValueError("已成交的委托不可撤单")
            self._check_account(db, account_id, day)
            db.execute("UPDATE paper_orders SET status = 'cancelled', cancelled_day = ? WHERE id = ?", (day, order_id))
            db.execute("UPDATE paper_account SET event_day = ? WHERE id = 1", (day,))
            return self._snapshot(db, day)

    def match_orders(self, *, account_id, day):
        """Explicit day-close checkpoint; never match the submitting day's bar."""
        day = trading_day(day)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._check_account(db, account_id, day)
            orders = db.execute("""SELECT id, request_id, fingerprint, symbol, side, day, quantity, limit_price,
                checked_day FROM paper_orders WHERE status = 'pending' ORDER BY id""").fetchall()
            prices = self._prices(db, day, {row[3] for row in orders})
            for order_id, request_id, fingerprint, symbol, side, placed_day, quantity, limit_price, checked_day in orders:
                if placed_day >= day:
                    note = "等待后续模拟日期"
                elif checked_day == day:
                    continue
                elif symbol not in prices or prices[symbol]["day"] != day:
                    note = "缺少该日有效日 K，等待获取行情后重试"
                else:
                    price = prices[symbol]["price"]
                    touched = price <= limit_price if side == "buy" else price >= limit_price
                    if touched:
                        # Release this order's reservation before filling, within the same transaction.
                        db.execute("""UPDATE paper_orders SET status = 'filled', checked_day = ?, check_note = NULL,
                            filled_day = ?, filled_price = ? WHERE id = ?""", (day, day, price, order_id))
                        self._execute_trade(db, request_id=request_id, fingerprint=fingerprint,
                                            symbol=symbol, side=side, day=day, quantity=quantity, price=price)
                        continue
                    note = "收盘价未满足限价"
                    db.execute("UPDATE paper_orders SET checked_day = ? WHERE id = ?", (day, order_id))
                db.execute("UPDATE paper_orders SET check_note = ? WHERE id = ?", (note, order_id))
            db.execute("UPDATE paper_account SET event_day = ? WHERE id = 1", (day,))
            return self._snapshot(db, day)

    def order(self, *, account_id, request_id, symbol, side, day, quantity, price):
        day = trading_day(day)
        self._validate_order(symbol, side, quantity, price, request_id)
        fingerprint = json.dumps([account_id, symbol, side, day, quantity, price])
        with self.connect() as db:
            # Serialize balance checks and ledger writes, including across processes.
            db.execute("BEGIN IMMEDIATE")
            self._check_account(db, account_id)
            if db.execute("SELECT 1 FROM paper_orders WHERE request_id = ?", (request_id,)).fetchone():
                raise ValueError("委托标识已被使用，请重新下单")
            previous = db.execute("SELECT fingerprint FROM paper_trades WHERE request_id = ?",
                                  (request_id,)).fetchone()
            if previous:
                if previous[0] != fingerprint:
                    raise ValueError("重复委托的内容不一致，请重新下单")
                return self._snapshot(db, day)
            self._check_account(db, account_id, day)
            quote = self._prices(db, day, {symbol}).get(symbol)
            if quote is None or quote["day"] != day:
                raise ValueError("所选日期没有可成交的日 K 行情，请先获取行情")
            if price != quote["price"]:
                raise ValueError("缓存收盘价已更新，请刷新报价后重新下单")
            self._execute_trade(db, request_id=request_id, fingerprint=fingerprint,
                                symbol=symbol, side=side, day=day, quantity=quantity, price=price)
            db.execute("UPDATE paper_account SET event_day = ? WHERE id = 1", (day,))
            return self._snapshot(db, day)

    def _execute_trade(self, db, *, request_id, fingerprint, symbol, side, day, quantity, price):
        cash = db.execute("SELECT cash FROM paper_account WHERE id = 1").fetchone()[0]
        free_cash = cash - self._frozen_cash(db)
        amount = price * quantity
        commission, stamp = fees(amount, side)
        position = db.execute("SELECT quantity, cost FROM paper_positions WHERE symbol = ?", (symbol,)).fetchone()
        held, cost = position or (0, 0)
        realized = 0
        if side == "buy":
            debit = amount + commission
            if debit > free_cash:
                raise ValueError("可用资金不足（含模拟佣金及挂单冻结资金）")
            cash -= debit
            db.execute("""INSERT INTO paper_positions VALUES (?, ?, ?)
                ON CONFLICT(symbol) DO UPDATE SET quantity = quantity + excluded.quantity,
                cost = cost + excluded.cost""", (symbol, quantity, debit))
            db.execute("INSERT INTO paper_lots (symbol, day, quantity) VALUES (?, ?, ?)", (symbol, day, quantity))
        else:
            lots = db.execute("""SELECT id, quantity FROM paper_lots
                WHERE symbol = ? AND day < ? AND quantity > 0 ORDER BY day, id""", (symbol, day)).fetchall()
            if quantity > sum(lot[1] for lot in lots) - self._frozen_shares(db, symbol):
                raise ValueError("可卖持仓不足；请检查 T+1 限制及其他挂单冻结的数量")
            remaining = quantity
            for lot_id, count in lots:
                taken = min(remaining, count)
                db.execute("UPDATE paper_lots SET quantity = quantity - ? WHERE id = ?", (taken, lot_id))
                remaining -= taken
                if not remaining:
                    break
            released_cost = int((Decimal(cost) * quantity / held).quantize(Decimal(1), rounding=ROUND_HALF_UP))
            proceeds = amount - commission - stamp
            if free_cash + proceeds < 0:
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

    def reset(self, account_id, day):
        day = trading_day(day)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT account_id FROM paper_account WHERE id = 1").fetchone()[0] != account_id:
                raise ValueError("模拟账户已重置，请刷新账户")
            for table in ("paper_orders", "paper_trades", "paper_lots", "paper_positions"):
                db.execute(f"DELETE FROM {table}")
            db.execute("UPDATE paper_account SET account_id = ?, cash = ?, realized = 0, last_day = NULL, event_day = NULL WHERE id = 1",
                       (uuid4().hex, INITIAL_CASH))
            return self._snapshot(db, day)
