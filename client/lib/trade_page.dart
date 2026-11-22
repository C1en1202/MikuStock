import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'market_data.dart';
import 'market_gateway.dart';
import 'paper_trading.dart';
import 'terminal_theme.dart';

class TradePage extends StatefulWidget {
  const TradePage({
    required this.gateway,
    required this.day,
    required this.security,
    required this.securityFor,
    super.key,
  });

  final MarketGateway gateway;
  final DateTime day;
  final Security security;
  final Security Function(String) securityFor;

  @override
  State<TradePage> createState() => _TradePageState();
}

class _TradePageState extends State<TradePage> {
  late final TextEditingController _code;
  final _quantity = TextEditingController(text: '100');
  PaperAccount? _account;
  PaperQuote? _quote;
  String _side = 'buy';
  String? _accountError;
  String? _quoteError;
  String? _notice;
  String? _orderSignature;
  String? _orderId;
  bool _loadingAccount = false;
  bool _loadingQuote = false;
  bool _submitting = false;
  int _accountRevision = 0;
  int _quoteRevision = 0;

  String get _day => dateKey(widget.day);
  int get _shares => int.tryParse(_quantity.text) ?? 0;
  bool get _busy => _loadingAccount || _loadingQuote || _submitting;
  bool get _backward =>
      _account?.lastDay != null && _day.compareTo(_account!.lastDay!) < 0;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: widget.security.code);
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant TradePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.security.symbol != oldWidget.security.symbol) {
      _code.text = widget.security.code;
    }
    if (widget.day != oldWidget.day ||
        widget.security.symbol != oldWidget.security.symbol) {
      _notice = null;
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _quantity.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await Future.wait([_loadAccount(), _loadQuote()]);
  }

  String _message(Object error) =>
      error is GatewayException ? error.message : '内置服务读取失败，请重试';

  Future<void> _loadAccount() async {
    final revision = ++_accountRevision;
    setState(() {
      _loadingAccount = true;
      _accountError = null;
    });
    try {
      final account = await widget.gateway.paperAccount(_day);
      if (mounted && revision == _accountRevision) {
        setState(() => _account = account);
      }
    } catch (error) {
      if (mounted && revision == _accountRevision) {
        setState(() {
          _account = null;
          _accountError = _message(error);
        });
      }
    } finally {
      if (mounted && revision == _accountRevision) {
        setState(() => _loadingAccount = false);
      }
    }
  }

  Future<void> _loadQuote({bool refresh = false}) async {
    final revision = ++_quoteRevision;
    final symbol = Security.parse(_code.text);
    final day = widget.day;
    setState(() {
      _quote = null;
      _quoteError = null;
      _loadingQuote = true;
    });
    try {
      if (symbol == null) {
        throw const GatewayException('请输入有效的沪深北 A 股证券代码');
      }
      if (refresh) {
        await widget.gateway.bars(
          symbol: symbol,
          interval: '1d',
          day: day,
          mode: MarketRead.refresh,
        );
      }
      final quote = await widget.gateway.paperQuote(symbol, dateKey(day));
      if (mounted && revision == _quoteRevision) {
        setState(() => _quote = quote);
        if (refresh) await _loadAccount();
      }
    } catch (error) {
      if (mounted && revision == _quoteRevision) {
        setState(() => _quoteError = _message(error));
      }
    } finally {
      if (mounted && revision == _quoteRevision) {
        setState(() => _loadingQuote = false);
      }
    }
  }

  void _choosePosition(PaperPosition position) {
    setState(() {
      _code.text = Security(position.symbol).code;
      _side = 'sell';
      _quantity.text = (position.available > 0 ? position.available : 100)
          .toString();
      _notice = null;
    });
    unawaited(_loadQuote());
  }

  PaperPosition? get _position => _account?.positions
      .where((position) => position.symbol == Security.parse(_code.text))
      .firstOrNull;

  String? get _validation {
    if (_backward) return '模拟日期早于最后成交日，请通过顶部日期按钮向后调整';
    if (_quote == null) return '取得所选日期的日 K 收盘价后可下单';
    if (_shares <= 0 || _shares > 100000000 || _shares % 100 != 0) {
      return '数量须为 100 股的整数倍，且不超过 1 亿股';
    }
    final amount = _quote!.price * _shares;
    if (_side == 'buy' &&
        amount + paperCommission(amount) > (_account?.cash ?? 0)) {
      return '可用资金不足（含模拟佣金）';
    }
    if (_side == 'sell' && _shares > (_position?.available ?? 0)) {
      return '可卖数量不足，当日买入的持仓次日才可卖出';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || _account == null || _validation != null) return;
    final quote = _quote!;
    final side = _side;
    final quantity = _shares;
    final signature =
        '${_account!.id}/${quote.symbol}/${quote.day}/'
        '${quote.price}/$side/$quantity';
    // Retain the identifier after an uncertain failure so retrying cannot double-fill.
    if (_orderSignature != signature) {
      _orderSignature = signature;
      _orderId =
          '${DateTime.now().microsecondsSinceEpoch}_'
          '${Random.secure().nextInt(1 << 32)}';
    }
    setState(() {
      _submitting = true;
      _notice = null;
    });
    try {
      final account = await widget.gateway.paperOrder(
        accountId: _account!.id,
        requestId: _orderId!,
        quote: quote,
        side: side,
        quantity: quantity,
      );
      if (!mounted) return;
      setState(() {
        _account = account;
        _notice =
            '模拟${side == 'buy' ? '买入' : '卖出'}成交：'
            '${Security(quote.symbol).code} · $quantity 股 · ¥${paperMoney(quote.price)}';
        _orderSignature = null;
        _orderId = null;
      });
      if (quote.day != _day) await _loadAccount();
    } catch (error) {
      if (mounted) {
        setState(() => _notice = '下单未确认：${_message(error)}。请刷新账户核对成交记录');
        await _loadAccount();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _reset() async {
    if (_busy || _account == null) return;
    final accountId = _account!.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置模拟账户？'),
        content: const Text('将清空全部模拟持仓和成交记录，并恢复 1,000,000.00 元虚拟资金。此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _busy) return;
    setState(() => _submitting = true);
    try {
      final account = await widget.gateway.resetPaperAccount(accountId, _day);
      if (mounted) {
        setState(() {
          _account = account;
          _orderSignature = null;
          _orderId = null;
          _notice = '模拟账户已重置';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _notice = '重置失败：${_message(error)}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TradePanel(
          title: '模拟交易',
          actions: [
            IconButton(
              tooltip: '刷新模拟账户及缓存报价',
              onPressed: _busy ? null : _reload,
              icon: const Icon(Icons.refresh),
            ),
            TextButton(
              onPressed: _busy || account == null ? null : _reset,
              child: const Text('重置账户'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loadingAccount) const LinearProgressIndicator(minHeight: 2),
              if (_accountError != null)
                Text(
                  _accountError!,
                  style: const TextStyle(color: terminalGold),
                ),
              if (account != null) ...[
                Wrap(
                  spacing: 28,
                  runSpacing: 16,
                  children: [
                    _metric('总资产', paperMoney(account.equity)),
                    _metric('可用资金', paperMoney(account.cash)),
                    _metric('持仓市值', paperMoney(account.marketValue)),
                    _metric(
                      '累计盈亏',
                      paperMoney(account.profit),
                      color: changeColor(account.profit.toDouble()),
                    ),
                    _metric(
                      '收益率',
                      '${(account.profit / account.initialCash * 100).toStringAsFixed(2)}%',
                      color: changeColor(account.profit.toDouble()),
                    ),
                    _metric(
                      '已实现盈亏',
                      paperMoney(account.realized),
                      color: changeColor(account.realized.toDouble()),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '估值截至 ${account.asOf} · 最后成交 ${account.lastDay ?? '暂无'} · 金额单位：元',
                  style: const TextStyle(color: terminalMuted, fontSize: 12),
                ),
                if (_backward)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '当前查看日期早于最后成交日，账户按最后成交日估值；请向后调整日期再下单。',
                      style: TextStyle(color: terminalGold),
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _TradePanel(
          title: '模拟下单',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 14,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 230,
                    child: TextField(
                      controller: _code,
                      enabled: !_submitting,
                      decoration: const InputDecoration(
                        labelText: '证券代码',
                        hintText: '600519 / 300033.SZ',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {
                        ++_quoteRevision;
                        _quote = null;
                        _loadingQuote = false;
                        _quoteError = null;
                        _notice = null;
                      }),
                      onSubmitted: (_) =>
                          _busy ? null : _loadQuote(refresh: true),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _loadQuote(refresh: true),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('获取 / 刷新日 K'),
                  ),
                  Text('模拟日期  $_day', style: numericStyle),
                ],
              ),
              const SizedBox(height: 12),
              if (_loadingQuote) const LinearProgressIndicator(minHeight: 2),
              if (_quote case final PaperQuote quote)
                Text(
                  '${widget.securityFor(quote.symbol).displayName} · '
                  '${quote.day} 缓存收盘价  ¥${paperMoney(quote.price)}',
                  style: numericStyle.copyWith(color: terminalBlue),
                ),
              if (_quoteError != null)
                Text(_quoteError!, style: const TextStyle(color: terminalGold)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'buy', label: Text('买入')),
                      ButtonSegment(value: 'sell', label: Text('卖出')),
                    ],
                    selected: {_side},
                    onSelectionChanged: _submitting
                        ? null
                        : (value) => setState(() {
                            _side = value.single;
                            _notice = null;
                          }),
                  ),
                  SizedBox(
                    width: 190,
                    child: TextField(
                      controller: _quantity,
                      enabled: !_submitting,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      decoration: const InputDecoration(
                        labelText: '数量（股）',
                        border: OutlineInputBorder(),
                        helperText: '100 股的整数倍',
                      ),
                      onChanged: (_) => setState(() => _notice = null),
                    ),
                  ),
                  if (_side == 'sell')
                    Text(
                      '持有 ${_position?.quantity ?? 0} 股 / 可卖 ${_position?.available ?? 0} 股',
                      style: numericStyle,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _estimate(),
              const SizedBox(height: 8),
              if (_validation != null)
                Text(
                  _validation!,
                  style: const TextStyle(color: terminalMuted, fontSize: 12),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _side == 'buy'
                        ? terminalRed
                        : terminalGreen,
                    foregroundColor: terminalBackground,
                  ),
                  onPressed: _busy || account == null || _validation != null
                      ? null
                      : _submit,
                  icon: Icon(
                    _submitting ? Icons.hourglass_top : Icons.swap_horiz,
                  ),
                  label: Text(
                    _submitting ? '正在处理…' : '模拟${_side == 'buy' ? '买入' : '卖出'}',
                  ),
                ),
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    _notice!,
                    style: const TextStyle(color: terminalGold),
                  ),
                ),
              const SizedBox(height: 14),
              const Text(
                '模拟规则：按所选日期未复权日 K 收盘价立即全额成交，不模拟排队、涨跌停和滑点。'
                '统一按 100 股整数倍买卖，T+1 可卖，成交日期不能倒退。'
                '\n费用假设：双向佣金 0.03%，每笔最低 5 元；卖出税费 0.05%，不计其他费用、分红和公司行动。'
                '以上仅为本模块的简化模拟参数。',
                style: TextStyle(
                  color: terminalMuted,
                  fontSize: 12,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _TradePanel(
          title: '我的持仓',
          child: account == null || account.positions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    '暂无持仓，模拟买入后在这里查看',
                    style: TextStyle(color: terminalMuted),
                  ),
                )
              : _positions(account),
        ),
        const SizedBox(height: 12),
        _TradePanel(
          title: '成交记录${account == null ? '' : ' · ${account.tradeCount} 笔'}',
          child: account == null || account.trades.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    '暂无模拟成交记录',
                    style: TextStyle(color: terminalMuted),
                  ),
                )
              : _trades(account),
        ),
      ],
    );
  }

  Widget _estimate() {
    if (_quote == null || _shares <= 0 || _shares > 100000000) {
      return const Text(
        '成交金额 —   模拟费用 —',
        style: TextStyle(color: terminalMuted),
      );
    }
    final amount = _quote!.price * _shares;
    final fee =
        paperCommission(amount) + (_side == 'sell' ? paperStamp(amount) : 0);
    return Text(
      '成交金额 ¥${paperMoney(amount)}   模拟费用 ¥${paperMoney(fee)}   '
      '${_side == 'buy' ? '预计支出' : '预计到账'} ¥${paperMoney(_side == 'buy' ? amount + fee : amount - fee)}',
      style: numericStyle,
    );
  }

  Widget _metric(String label, String value, {Color color = terminalText}) =>
      SizedBox(
        width: 170,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: terminalMuted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: numericStyle.copyWith(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      );

  Widget _table(
    List<String> headers,
    List<DataRow> rows,
  ) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      columnSpacing: 24,
      horizontalMargin: 0,
      headingTextStyle: const TextStyle(color: terminalMuted, fontSize: 12),
      dataTextStyle: numericStyle.copyWith(color: terminalText, fontSize: 13),
      columns: [for (final title in headers) DataColumn(label: Text(title))],
      rows: rows,
    ),
  );

  DataCell _cell(String value, {Color? color}) =>
      DataCell(Text(value, style: TextStyle(color: color)));

  Widget _positions(PaperAccount account) => _table(
    ['证券', '持仓 / 可卖', '成本均价（含佣金）', '估值价格', '行情日期', '持仓市值', '浮动盈亏', '操作'],
    [
      for (final position in account.positions)
        DataRow(
          cells: [
            _cell(
              '${widget.securityFor(position.symbol).displayName}\n${Security(position.symbol).code}',
            ),
            _cell('${position.quantity} / ${position.available}'),
            _cell(paperMoney(position.cost / position.quantity)),
            _cell(
              position.price == null ? '按成本估值' : paperMoney(position.price!),
            ),
            _cell(
              position.priceDay == null
                  ? '缺少行情'
                  : '${position.priceDay}${position.priceDay == account.asOf ? '' : '（沿用）'}',
              color: position.priceDay == account.asOf
                  ? terminalMuted
                  : terminalGold,
            ),
            _cell(paperMoney(position.marketValue)),
            _cell(
              paperMoney(position.unrealized),
              color: changeColor(position.unrealized.toDouble()),
            ),
            DataCell(
              TextButton(
                onPressed: _busy ? null : () => _choosePosition(position),
                child: const Text('卖出'),
              ),
            ),
          ],
        ),
    ],
  );

  Widget _trades(PaperAccount account) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '展示最近 200 笔成交；完整记录保存在本地账户中。',
        style: TextStyle(color: terminalMuted, fontSize: 12),
      ),
      const SizedBox(height: 6),
      _table(
        ['编号', '模拟日期', '证券', '方向', '成交价', '数量', '成交金额', '佣金 / 税费', '已实现盈亏'],
        [
          for (final trade in account.trades)
            DataRow(
              cells: [
                _cell('#${trade.id}'),
                _cell(trade.day),
                _cell(
                  '${widget.securityFor(trade.symbol).displayName}\n${Security(trade.symbol).code}',
                ),
                _cell(
                  trade.side == 'buy' ? '买入' : '卖出',
                  color: trade.side == 'buy' ? terminalRed : terminalGreen,
                ),
                _cell(paperMoney(trade.price)),
                _cell('${trade.quantity}'),
                _cell(paperMoney(trade.amount)),
                _cell(
                  '${paperMoney(trade.commission)} / ${paperMoney(trade.stamp)}',
                ),
                _cell(
                  trade.side == 'buy' ? '—' : paperMoney(trade.realized),
                  color: changeColor(trade.realized.toDouble()),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

class _TradePanel extends StatelessWidget {
  const _TradePanel({
    required this.title,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Material(
    color: terminalPanel,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: terminalBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}
