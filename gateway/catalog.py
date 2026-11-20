"""On-demand stock names from quote metadata and exchange directories."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Lock

from .market_data import UpstreamError
from .symbols import catalog_group, parse_symbol


GROUPS = ("sh_main", "sh_star", "sz", "bj")
MAX_AGE = timedelta(hours=24)


class StockCatalog:
    def __init__(self, connect, worker):
        self.connect = connect
        self.worker = worker
        self.locks = {group: Lock() for group in GROUPS}
        with connect() as db:
            db.execute("""
                CREATE TABLE IF NOT EXISTS stock_names (
                    symbol TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    fetched_at TEXT NOT NULL
                )
            """)
            db.execute("""
                CREATE TABLE IF NOT EXISTS stock_catalog_refresh (
                    board TEXT PRIMARY KEY,
                    fetched_at TEXT NOT NULL
                )
            """)

    def for_symbols(self, symbols, *, fresh=False):
        symbols = list(dict.fromkeys(symbols))[:100]
        if not symbols:
            return []
        cutoff = (datetime.now(timezone.utc) - MAX_AGE).isoformat() if fresh else ""
        with self.connect() as db:
            rows = db.execute(
                f"SELECT symbol, name FROM stock_names WHERE fetched_at >= ? "
                f"AND symbol IN ({','.join('?' for _ in symbols)})",
                [cutoff, *symbols],
            ).fetchall()
        return [dict(symbol=symbol, name=name) for symbol, name in rows]

    def search(self, text):
        keyword = text.strip()
        if not keyword or len(keyword) > 32:
            raise ValueError("Enter a stock code or name up to 32 characters")
        symbol = parse_symbol(keyword)
        if symbol:
            if names := self.for_symbols([symbol], fresh=True):
                return {"matches": names, "unavailable": []}
            try:
                names = self.worker(["name", symbol])
                self._store(item for item in names if item.get("symbol") == symbol)
            except UpstreamError:
                pass
            if names := self.for_symbols([symbol], fresh=True):
                return {"matches": names, "unavailable": []}
            groups = [catalog_group(symbol)]
        else:
            try:
                suggestions = self.worker(["suggest", keyword])
                if self._store(suggestions):
                    matches = {
                        row["symbol"]: row for row in [*suggestions, *self._find(keyword)]
                    }
                    return {"matches": list(matches.values())[:24], "unavailable": []}
            except UpstreamError:
                pass
            groups = GROUPS
        with ThreadPoolExecutor(max_workers=len(groups)) as pool:
            unavailable = [group for group, ok in zip(groups, pool.map(self._refresh, groups)) if not ok]
        return {
            "matches": self.for_symbols([symbol]) if symbol else self._find(keyword),
            "unavailable": unavailable,
        }

    def _find(self, keyword):
        with self.connect() as db:
            rows = db.execute("""
                SELECT symbol, name FROM stock_names
                WHERE instr(name, ?) > 0 OR instr(symbol, ?) > 0
                ORDER BY (name = ?) DESC, (instr(name, ?) = 1) DESC, symbol
                LIMIT 24
            """, (keyword, keyword.lower(), keyword, keyword)).fetchall()
        return [dict(symbol=symbol, name=name) for symbol, name in rows]

    def _refresh(self, group):
        with self.locks[group]:
            with self.connect() as db:
                row = db.execute(
                    "SELECT fetched_at FROM stock_catalog_refresh WHERE board = ?", (group,)
                ).fetchone()
            if row and datetime.now(timezone.utc) - datetime.fromisoformat(row[0]) < MAX_AGE:
                return True
            try:
                names = self.worker(["catalog", group], timeout=55 if group == "bj" else 25)
            except UpstreamError:
                return False
            return self._store(
                (item for item in names if catalog_group(item.get("symbol", "")) == group),
                group,
            )

    def _store(self, items, group=None):
        rows = []
        for item in items:
            symbol = item.get("symbol", "")
            name = item.get("name", "").strip()
            if symbol and parse_symbol(symbol) == symbol and name and name.lower() not in {"nan", "none"}:
                rows.append((symbol, name))
        if not rows:
            return False
        fetched_at = datetime.now(timezone.utc).isoformat()
        with self.connect() as db:
            db.executemany("""
                INSERT INTO stock_names VALUES (?, ?, ?)
                ON CONFLICT(symbol) DO UPDATE SET
                    name = excluded.name, fetched_at = excluded.fetched_at
            """, ((symbol, name, fetched_at) for symbol, name in rows))
            if group:
                db.execute("""
                    INSERT INTO stock_catalog_refresh VALUES (?, ?)
                    ON CONFLICT(board) DO UPDATE SET fetched_at = excluded.fetched_at
                """, (group, fetched_at))
        return True
