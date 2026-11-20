"""Bounded live API smoke probes. Run with the project virtual environment."""
import concurrent.futures
import datetime as dt
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

CASES = {
    'snapshot': ('stock_zh_a_spot_em', {}),
    'quote': ('stock_bid_ask_em', {'symbol': '000001'}),
    'minute': ('stock_zh_a_hist_min_em', {'symbol': '000001', 'period': '1', 'adjust': ''}),
    'daily': ('stock_zh_a_hist_em', {'symbol': '000001', 'period': 'daily', 'start_date': '20261101', 'end_date': '20261120', 'adjust': ''}),
}
if '--fallback' in sys.argv:
    CASES = {
        'snapshot_tx': ('stock_zh_a_spot_tx', {}),
        'snapshot_sina': ('stock_zh_a_spot_sina', {}),
        'daily_tx': ('stock_zh_a_hist_tx', {'symbol': 'sz000001', 'start_date': '20261101', 'end_date': '20261120', 'adjust': ''}),
        'daily_sina': ('stock_zh_a_hist_sina', {'symbol': 'sz000001', 'start_date': '20261101', 'end_date': '20261120', 'adjust': ''}),
    }
if '--verify' in sys.argv:
    CASES = {
        'minute_sina': ('stock_zh_a_hist_min_sina', {'symbol': 'sz000001', 'period': '1', 'adjust': ''}),
        'daily_sh_tx': ('stock_zh_a_hist_tx', {'symbol': 'sh600519', 'start_date': '20261101', 'end_date': '20261120', 'adjust': ''}),
    }
if '--stage1' in sys.argv:
    CASES = {
        'directory_sh': ('stock_info_sh_name_code', {'symbol': '主板A股'}),
        'directory_sz': ('stock_info_sz_name_code', {'symbol': 'A股列表'}),
        'calendar': ('calendar_trade_date_hist_sina', {}),
        'suspensions': ('stock_tfp_em', {'date': '20261120'}),
        'minute_sh': ('stock_zh_a_hist_min_sina', {'symbol': 'sh600519', 'period': '1', 'adjust': ''}),
        'minute_sz': ('stock_zh_a_hist_min_sina', {'symbol': 'sz000001', 'period': '1', 'adjust': ''}),
    }

def child(case):
    import akshare as ak
    import requests
    original = requests.sessions.Session.request
    def bounded(self, method, url, **kwargs):
        if '--direct' in sys.argv:
            self.trust_env = False
        kwargs['timeout'] = (8, 20)
        response = original(self, method, url, **kwargs)
        response.raise_for_status()
        return response
    requests.sessions.Session.request = bounded
    name, kwargs = CASES[case]
    started = time.monotonic()
    result = {'case': case, 'function': name, 'parameters': kwargs}
    try:
        frame = getattr(ak, name)(**kwargs)
        result.update(status='ok' if len(frame) else 'empty', rows=len(frame), columns=list(frame.columns), sample=json.loads(frame.tail(3).to_json(orient='records', force_ascii=False, date_format='iso')))
        if len(frame) and {'open', 'high', 'low', 'close'}.issubset(frame.columns):
            import pandas as pd
            prices = frame[['open', 'high', 'low', 'close']].apply(pd.to_numeric, errors='coerce')
            time_col = 'date' if 'date' in frame else 'day'
            times = pd.to_datetime(frame[time_col], errors='coerce')
            result['validation'] = {
                'prices_numeric': bool(prices.notna().all().all()),
                'prices_positive': bool((prices > 0).all().all()),
                'ohlc_consistent': bool(((prices.high >= prices[['open', 'close', 'low']].max(axis=1)) & (prices.low <= prices[['open', 'close', 'high']].min(axis=1))).all()),
                'times_valid': bool(times.notna().all()),
                'times_sorted': bool(times.is_monotonic_increasing),
                'times_unique': bool(times.is_unique),
                'first_time': str(times.min()), 'last_time': str(times.max()),
            }
    except Exception as exc:
        result.update(status='error', error_type=type(exc).__name__, error=str(exc)[:1200])
    result['elapsed_seconds'] = round(time.monotonic() - started, 2)
    print('PROBE_RESULT=' + json.dumps(result, ensure_ascii=False))

def run(case):
    try:
        args = [sys.executable, __file__]
        if '--direct' in sys.argv:
            args.append('--direct')
        if '--fallback' in sys.argv:
            args.append('--fallback')
        if '--verify' in sys.argv:
            args.append('--verify')
        if '--stage1' in sys.argv:
            args.append('--stage1')
        p = subprocess.run(args + ['--case', case], capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=75)
        for line in reversed(p.stdout.splitlines()):
            if line.startswith('PROBE_RESULT='):
                return json.loads(line.removeprefix('PROBE_RESULT='))
        return {'case': case, 'status': 'process_error', 'returncode': p.returncode, 'detail': p.stderr[-1000:]}
    except subprocess.TimeoutExpired:
        return {'case': case, 'status': 'timeout', 'timeout_seconds': 75}

if __name__ == '__main__':
    if '--case' in sys.argv:
        child(sys.argv[-1])
    else:
        report = {'tested_at': dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(), 'akshare_version': importlib.metadata.version('akshare'), 'symbol': '000001', 'note': 'Single request per endpoint; success does not establish freshness, stability, or redistribution rights.', 'results': []}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for result in pool.map(run, CASES):
                report['results'].append(result)
                print(json.dumps(result, ensure_ascii=False), flush=True)
        report['network_mode'] = 'direct' if '--direct' in sys.argv else 'system_proxy'
        mode = next((name for name in ('--stage1', '--verify', '--fallback') if name in sys.argv), '')
        suffix = mode[1:] + ('-direct' if '--direct' in sys.argv else '')
        dest = Path(__file__).resolve().parents[1] / 'artifacts' / f'akshare-probe{suffix}.json'
        dest.parent.mkdir(exist_ok=True)
        dest.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(str(dest))
