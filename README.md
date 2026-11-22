# MikuStock

## 模拟交易

从侧栏「交易」或行情卡片上的交易按钮进入。账户初始拥有 **1,000,000 元虚拟资金**，支持买入、卖出、持仓估值、累计与已实现盈亏、最近 200 笔成交记录，以及确认后重置账户。完整成交记录保存在本地数据库中。

1. 在顶部选择模拟日期，输入沪深北 A 股代码。
2. 点击「获取 / 刷新日 K」获取该日期行情；已有缓存时进入页面即可读取报价。
3. 选择买卖方向、输入股数，核对金额与费用后点击模拟买入或卖出。持仓中的「卖出」可直接带入证券与可卖数量。

当前采用**历史收盘价立即全额成交**，并非实时委托撮合。只有所选日期存在成交量大于零的未复权日 K 才能下单；不会使用此前交易日价格替代成交。统一按 100 股整数倍买卖，T+1 可卖，成交日期不得早于最后成交日。回看更早日期时，账户仍显示最后成交日的持仓与估值；如需重新开始另一段模拟，可重置账户。

模拟费用固定假设为双向佣金 0.03%（每笔最低 5 元），卖出税费 0.05%，每项四舍五入至分；不计其他费用、分红、公司行动、排队、涨跌停及滑点。这些是简化模拟参数。买入佣金计入持仓成本，卖出按平均成本结转已实现盈亏。资金和成本均按整数分记账，委托写入使用数据库事务并支持重复请求去重。

估值使用不晚于模拟日期的本地缓存日 K，并显示各持仓行情日期；缺少当日行情时沿用之前价格，完全缺少价格时明确按成本估值。点击获取行情可更新当前证券的估值。账户与行情共用本地 `market.sqlite3`，桌面版默认位于 `%LOCALAPPDATA%\MikuStock`，可通过 `MIKUSTOCK_DATA_DIR` 指定目录。

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

客户端静态检查与组件测试（在 `client` 目录执行）：

```powershell
flutter analyze
flutter test
```
