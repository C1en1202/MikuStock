"""Run one AKShare call in a disposable, time-bounded worker process."""

from datetime import date
from decimal import Decimal
import json
import re
import sys
from urllib.parse import quote

import akshare
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


def fetch(source, symbol, interval, start, end):
    if source == "eastmoney":
        return fetch_eastmoney(symbol, interval, start, end)
    if interval == "1m":
        return akshare.stock_zh_a_hist_min_sina(symbol=symbol, period="1", adjust="")
    daily = akshare.stock_zh_a_hist_tx if source == "tencent" else akshare.stock_zh_a_hist_sina
    return daily(
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
                    for row in frame.to_dict("records")
                ]
        payload = {"rows": rows}
    except requests.HTTPError as exc:
        status = exc.response.status_code
        payload = {"error": "rate_limited" if status == 429 else
                   "server_error" if status >= 500 else "http_error"}
    except requests.Timeout:
        payload = {"error": "timeout"}
    except requests.exceptions.SSLError:
        payload = {"error": "tls_error"}
    except requests.ConnectionError:
        payload = {"error": "connection"}
    except Exception:
        payload = {"error": "invalid_response"}
    print("RESULT=" + json.dumps(payload))


if __name__ == "__main__":
    main()
