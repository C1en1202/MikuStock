"""Run one AKShare call in a disposable, time-bounded worker process."""

from datetime import date
from decimal import Decimal
import json
import re
import sys
from urllib.parse import quote

import akshare
from akshare.exceptions import RateLimitError
import requests

from .symbols import parse_symbol


def names_for_group(group):
    if group == "sz":
        frame = akshare.stock_info_sz_name_code(symbol="A股列表")
        exchange, code, name = "sz", "A股代码", "A股简称"
    elif group == "bj":
        frame = akshare.stock_info_bj_name_code()
        exchange, code, name = "bj", "证券代码", "证券简称"
    elif group in {"sh_main", "sh_star"}:
        frame = akshare.stock_info_sh_name_code(symbol="科创板" if group == "sh_star" else "主板A股")
        exchange, code, name = "sh", "证券代码", "证券简称"
    else:
        raise ValueError("unknown stock catalog")
    return [
        {"symbol": exchange + str(row[code]).zfill(6), "name": str(row[name])}
        for row in frame[[code, name]].to_dict("records")
    ]


def quote_name(symbol):
    if parse_symbol(symbol) != symbol:
        raise ValueError("invalid stock symbol")
    response = requests.get(f"https://qt.gtimg.cn/q={symbol}")
    text = decode_quote(response.content)
    match = re.search(rf'\bv_{symbol}="([^"]*)"', text)
    fields = match[1].split("~") if match else []
    if len(fields) > 2 and fields[2] == symbol[2:] and fields[1].strip():
        return [{"symbol": symbol, "name": fields[1].strip()}]
    return []


def decode_quote(payload):
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload.decode("gb18030")


def suggest_names(keyword):
    if not keyword or len(keyword) > 32:
        raise ValueError("invalid stock search")
    url = f"https://suggest3.sinajs.cn/suggest/type=11&key={quote(keyword, safe='')}&name=suggestdata"
    text = decode_quote(requests.get(url).content)
    match = re.search(r'\bvar\s+suggestdata="([^"]*)"', text)
    if not match:
        raise ValueError("invalid stock search response")
    result = []
    for row in match[1].split(";"):
        fields = row.split(",")
        if len(fields) < 4:
            continue
        name, kind, code, symbol = fields[:4]
        if kind == "11" and parse_symbol(symbol) == symbol and symbol[2:] == code and name.strip():
            result.append({"symbol": symbol, "name": name.strip()})
    return result


def fetch_eastmoney(symbol, interval, start, end):
    if interval == "1m":
        frame = akshare.stock_zh_a_hist_min_em(
            symbol=symbol[2:], period="1", adjust="",
            start_date=f"{start} 09:31:00", end_date=f"{end} 15:00:00",
        )
        date_column, label = "时间", "day"
    else:
        frame = akshare.stock_zh_a_hist_em(
            symbol=symbol[2:], period="daily", adjust="",
            start_date=start.replace("-", ""), end_date=end.replace("-", ""),
        )
        date_column, label = "日期", "date"
    frame = frame.rename(columns={
        date_column: label, "开盘": "open", "收盘": "close", "最高": "high",
        "最低": "low", "成交量": "volume", "成交额": "amount",
    })
    if not frame.empty:
        frame["volume"] = frame["volume"].map(lambda lots: Decimal(str(lots)) * 100)
    return frame


def fetch_tencent(symbol, start, end):
    """Fetch the requested unadjusted range without the optional listing-date service."""
    # The AKShare Tencent helper first calls weekTrends on a separate host to
    # discover the listing date. A failure there prevents a working K-line
    # endpoint from being queried at all. BarQuery already bounds our date range.
    response = requests.get(
        "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get",
        params={"param": f"{symbol},day,{start},{end},640,"},
    )
    text = response.text.strip()
    payload = json.loads(text[text.index("{"):].rstrip(";"), parse_float=Decimal)
    if not isinstance(payload, dict) or payload.get("code") != 0 or not isinstance(payload.get("data"), dict):
        raise ValueError("invalid Tencent K-line response")
    data = payload["data"].get(symbol)
    if not isinstance(data, dict):
        raise ValueError("missing Tencent security data")
    if "day" not in data and any(key in data for key in ("qfqday", "hfqday")):
        raise ValueError("expected unadjusted Tencent prices")
    rows = data.get("day", [])
    if not isinstance(rows, list):
        raise ValueError("invalid Tencent daily bars")
    result = []
    # Match the units of the pinned AKShare adapter: STAR volume is already
    # shares, other supported A-share boards use lots; turnover amounts use 10k CNY.
    multiplier = 1 if symbol.startswith(("sh688", "sh689")) else 100
    for row in rows:
        if not isinstance(row, list) or len(row) < 9:
            raise ValueError("invalid Tencent daily row")
        day = date.fromisoformat(str(row[0])).isoformat()
        if start <= day <= end:
            result.append(dict(
                date=day, open=str(row[1]), close=str(row[2]), high=str(row[3]), low=str(row[4]),
                volume=str(Decimal(str(row[5])) * multiplier),
                amount=str(Decimal(str(row[8])) * 10000),
            ))
    return result


def fetch(source, symbol, interval, start, end):
    if source == "eastmoney":
        return fetch_eastmoney(symbol, interval, start, end)
    if interval == "1m":
        return akshare.stock_zh_a_hist_min_sina(symbol=symbol, period="1", adjust="")
    if source == "tencent":
        return fetch_tencent(symbol, start, end)
    return akshare.stock_zh_a_hist_sina(
        symbol=symbol, start_date=date.fromisoformat(start).strftime("%Y%m%d"),
        end_date=date.fromisoformat(end).strftime("%Y%m%d"), adjust="",
    )


def main():
    original = requests.Session.request
    arguments = sys.argv[1:]
    direct = arguments[-1:] == ["--direct"]
    if direct:
        arguments.pop()

    def bounded(session, method, url, **kwargs):
        if direct:
            session.trust_env = False
            kwargs["proxies"] = {}
        kwargs["timeout"] = (5, 8)
        response = original(session, method, url, **kwargs)
        response.raise_for_status()
        return response

    requests.Session.request = bounded
    try:
        match arguments:
            case ["name", symbol]:
                rows = quote_name(symbol)
            case ["catalog", group]:
                rows = names_for_group(group)
            case ["suggest", keyword]:
                rows = suggest_names(keyword)
            case _:
                frame = fetch(*arguments)
                # Preserve upstream strings and the round-trip representation of floats.
                rows = [
                    {key: str(value) for key, value in row.items()}
                    for row in (frame if isinstance(frame, list) else frame.to_dict("records"))
                ]
        payload = {"rows": rows}
    except RateLimitError:
        payload = {"error": "rate_limited"}
    except requests.HTTPError as exc:
        status = exc.response.status_code
        payload = {"error": "rate_limited" if status == 429 else
                   "server_error" if status >= 500 else "http_error"}
    except requests.Timeout:
        payload = {"error": "timeout"}
    except requests.exceptions.ProxyError:
        payload = {"error": "proxy_error"}
    except requests.exceptions.SSLError:
        payload = {"error": "tls_error"}
    except (requests.ConnectionError, requests.exceptions.ChunkedEncodingError):
        payload = {"error": "connection"}
    except Exception:
        payload = {"error": "invalid_response"}
    print("RESULT=" + json.dumps(payload))


if __name__ == "__main__":
    main()
