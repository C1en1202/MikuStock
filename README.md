# MikuStock

## 构建客户端

需要 Flutter Stable SDK、Visual Studio 的「使用 C++ 的桌面开发」工作负载，以及已安装 `requirements.txt` 的 Python 3.12 构建环境。

```powershell
.\scripts\build_windows.ps1
```

## 独立 HTTP 网关开发调试

在项目根目录使用 PowerShell。现有 `.venv` 可直接使用，新环境可通过 Python 3.12 重建。

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m gateway
```

服务监听 `127.0.0.1:8765`，默认数据库为 `data/market.sqlite3`。可用 `--port`、`--db` 修改。默认使用环境代理。`--direct` 仅让该网关的 AKShare 请求直连，上游请求始终启用 TLS 校验。

在另一终端查询健康状态和历史行情。

```powershell
Invoke-RestMethod 'http://127.0.0.1:8765/health'
Invoke-RestMethod 'http://127.0.0.1:8765/v1/bars?symbol=sz000001&interval=1d&start=2026-11-02&end=2026-11-20'
Invoke-RestMethod 'http://127.0.0.1:8765/v1/bars?symbol=sz000001&interval=1m&start=2026-11-20&end=2026-11-20'
```

## 验证

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\.venv\Scripts\python.exe scripts\probe_akshare.py --stage1 --direct
```
