import 'package:material_ui/material_ui.dart';

import 'market_chart.dart';
import 'market_data.dart';
import 'terminal_theme.dart';
import 'window_controls.dart';

enum TerminalPage { watchlist, trade, search, market }

class TerminalHeader extends StatelessWidget {
  const TerminalHeader({
    required this.date,
    required this.onDate,
    required this.onSearch,
    required this.onRefresh,
    super.key,
  });

  final String date;
  final VoidCallback onDate;
  final VoidCallback onSearch;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    padding: const EdgeInsets.only(left: 14),
    decoration: const BoxDecoration(
      color: terminalHeader,
      border: Border(bottom: BorderSide(color: terminalBorder)),
    ),
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowAction('drag'),
            onDoubleTap: () => windowAction('toggleMaximize'),
            child: SizedBox.expand(
              child: Row(
                children: [
                  Image.asset('assets/miku-icon.png', width: 34, height: 34),
                  const SizedBox(width: 8),
                  const Flexible(
                    child: Text(
                      'MikuStock',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onDate,
          icon: const Icon(Icons.calendar_today_outlined, size: 15),
          label: Text(date, style: numericStyle),
          style: TextButton.styleFrom(foregroundColor: terminalMuted),
        ),
        IconButton(
          tooltip: '股票查询',
          onPressed: onSearch,
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: '刷新当前行情',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        const SizedBox(width: 5),
        const WindowButtons(),
      ],
    ),
  );
}

class TerminalSidebar extends StatelessWidget {
  const TerminalSidebar({
    required this.compact,
    required this.section,
    required this.onSelect,
    super.key,
  });

  final bool compact;
  final TerminalPage section;
  final ValueChanged<TerminalPage> onSelect;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: terminalPanel,
      border: Border(right: BorderSide(color: terminalBorder)),
    ),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(8, 15, 8, 10),
      children: [
        _item(Icons.star_rounded, '自选', TerminalPage.watchlist),
        _item(Icons.swap_horiz_rounded, '交易', TerminalPage.trade),
        _item(Icons.search_rounded, '股票查询', TerminalPage.search),
        _item(Icons.insert_chart_outlined_rounded, '行情', TerminalPage.market),
      ],
    ),
  );

  Widget _item(IconData icon, String label, TerminalPage page) {
    final selected = section == page;
    final color = selected ? terminalText : terminalMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: label,
        child: TextButton(
          onPressed: () => onSelect(page),
          style: TextButton.styleFrom(
            foregroundColor: color,
            disabledForegroundColor: terminalMuted.withValues(alpha: 0.48),
            backgroundColor: selected ? const Color(0xff1b3e72) : null,
            minimumSize: const Size(0, 43),
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
          ),
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Icon(icon, size: 21),
              if (!compact) ...[const SizedBox(width: 10), Text(label)],
            ],
          ),
        ),
      ),
    );
  }
}

class WatchlistPanel extends StatelessWidget {
  const WatchlistPanel({
    required this.securities,
    required this.selected,
    required this.exchange,
    required this.onExchange,
    required this.onSelect,
    required this.onAdd,
    required this.onRefresh,
    required this.daily,
    super.key,
  });

  final List<Security> securities;
  final Security selected;
  final String exchange;
  final ValueChanged<String> onExchange;
  final ValueChanged<Security> onSelect;
  final VoidCallback onAdd;
  final VoidCallback? onRefresh;
  final MarketSnapshot? Function(Security) daily;

  @override
  Widget build(BuildContext context) => _Panel(
    child: SizedBox(
      height: 464,
      child: LayoutBuilder(
        builder: (context, size) {
          final showVolume = size.maxWidth >= 430;
          final showAmount = size.maxWidth >= 505;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PanelHeading(
                title: '自选股',
                actions: [
                  IconButton(
                    tooltip: '刷新当前列表日线',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                  IconButton(
                    tooltip: '添加自选',
                    onPressed: onAdd,
                    icon: const Icon(Icons.add, size: 22),
                  ),
                ],
              ),
              _TabStrip(
                tabs: const {'全部': '全部', 'SH': '沪市', 'SZ': '深市', 'BJ': '北交所'},
                selected: exchange,
                onSelect: onExchange,
              ),
              _row(
                name: const Text(
                  '名称／代码',
                  style: TextStyle(color: terminalMuted),
                ),
                values: [
                  '收盘价',
                  '涨跌',
                  '涨跌幅',
                  if (showVolume) '成交量',
                  if (showAmount) '成交额',
                ],
                color: terminalMuted,
                height: 36,
              ),
              Expanded(
                child: securities.isEmpty
                    ? const _PanelMessage('当前列表没有自选股')
                    : ListView.builder(
                        itemCount: securities.length,
                        itemBuilder: (context, index) {
                          final item = securities[index];
                          final snapshot = daily(item);
                          final bar = snapshot?.bars.lastOrNull;
                          final change = bar == null
                              ? null
                              : QuoteChange.fromBars(snapshot!.bars, bar);
                          final picked = item.symbol == selected.symbol;
                          return Tooltip(
                            message: bar == null
                                ? '点击读取 ${item.code} 行情'
                                : '${bar.time} · ${snapshot!.source}${snapshot.status == 'cached' ? '缓存' : ''}',
                            child: Material(
                              color: picked
                                  ? terminalSurface
                                  : Colors.transparent,
                              child: InkWell(
                                onTap: () => onSelect(item),
                                child: _row(
                                  name: Row(
                                    children: [
                                      const Icon(
                                        Icons.star_rounded,
                                        size: 18,
                                        color: terminalGold,
                                      ),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              item.displayName,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            if (item.name.isNotEmpty)
                                              Text(
                                                item.code,
                                                style: numericStyle.copyWith(
                                                  color: terminalMuted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  values: [
                                    bar?.close ?? '—',
                                    change == null ? '—' : signed(change.value),
                                    change == null
                                        ? '—'
                                        : '${signed(change.percent)}%',
                                    if (showVolume)
                                      bar == null
                                          ? '—'
                                          : compactNumber(bar.volume),
                                    if (showAmount)
                                      bar == null
                                          ? '—'
                                          : compactNumber(
                                              double.parse(bar.amount),
                                            ),
                                  ],
                                  color: bar == null
                                      ? terminalMuted
                                      : changeColor(change?.value),
                                  neutralFrom: 3,
                                  height: 52,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _row({
    required Widget name,
    required List<String> values,
    required Color color,
    required double height,
    int? neutralFrom,
  }) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: terminalBorder)),
    ),
    child: Row(
      children: [
        Expanded(flex: 7, child: name),
        for (final (index, value) in values.indexed)
          Expanded(
            flex: index == 0 ? 5 : 4,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: numericStyle.copyWith(
                color:
                    neutralFrom != null && index >= neutralFrom && value != '—'
                    ? terminalText
                    : color,
                fontSize: 12,
              ),
            ),
          ),
      ],
    ),
  );
}

class QuotePanel extends StatelessWidget {
  const QuotePanel({
    required this.security,
    required this.interval,
    required this.snapshot,
    required this.daily,
    required this.loading,
    required this.error,
    required this.favorite,
    required this.onFavorite,
    required this.onInterval,
    required this.onRefresh,
    required this.onTrade,
    super.key,
  });

  final Security security;
  final String interval;
  final MarketSnapshot? snapshot;
  final MarketSnapshot? daily;
  final bool loading;
  final String? error;
  final bool favorite;
  final VoidCallback onFavorite;
  final ValueChanged<String> onInterval;
  final VoidCallback onRefresh;
  final VoidCallback onTrade;

  @override
  Widget build(BuildContext context) {
    final bars = snapshot?.bars ?? const <MarketBar>[];
    final last = bars.lastOrNull;
    final change = last == null
        ? null
        : QuoteChange.fromBars(daily?.bars ?? [], last);
    final color = changeColor(change?.value);
    return _Panel(
      child: SizedBox(
        height: 464,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 12, 9, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          security.name.isEmpty
                              ? security.code
                              : '${security.code}  ${security.name}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: favorite ? '取消自选' : '加入自选',
                        onPressed: onFavorite,
                        icon: Icon(
                          favorite
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: favorite ? terminalGold : terminalMuted,
                          size: 21,
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新行情',
                        onPressed: loading ? null : onRefresh,
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
                      IconButton(
                        tooltip: '模拟交易该证券',
                        onPressed: onTrade,
                        icon: const Icon(Icons.swap_horiz, size: 20),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        last?.close ?? '—',
                        style: numericStyle.copyWith(
                          fontSize: 33,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                          color: color,
                        ),
                      ),
                      if (change != null)
                        Text(
                          '${signed(change.value)}  ${signed(change.percent)}%',
                          style: numericStyle.copyWith(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    last == null
                        ? '历史行情 · 未复权'
                        : '${marketTime(last.time)}  ·  ${snapshot!.source}${snapshot!.status == 'cached' || error != null ? '  ·  缓存行情' : ''}',
                    style: const TextStyle(color: terminalMuted, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            _TabStrip(
              tabs: const {'1m': '分时', '1d': '日 K'},
              selected: interval,
              onSelect: onInterval,
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: bars.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(10, 11, 12, 7),
                      child: MarketChart(bars, minute: interval == '1m'),
                    )
                  : _PanelMessage(
                      loading
                          ? '正在读取历史行情…'
                          : error ??
                                (snapshot == null
                                    ? '本地暂无该日期的行情'
                                    : '所选日期没有可用行情'),
                      onRetry: loading ? null : onRefresh,
                      actionLabel: error == null ? '获取行情' : '重试',
                    ),
            ),
            if (last != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(15, 0, 12, 11),
                child: Text(
                  error ??
                      '开 ${last.open}   高 ${last.high}   低 ${last.low}   收 ${last.close}',
                  style: numericStyle.copyWith(
                    color: terminalMuted,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class OverviewPanel extends StatelessWidget {
  const OverviewPanel({
    required this.securities,
    required this.daily,
    required this.onSelect,
    super.key,
  });

  final List<Security> securities;
  final MarketSnapshot? Function(Security) daily;
  final ValueChanged<Security> onSelect;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PanelHeading(title: '自选概览'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: securities.isEmpty
              ? const SizedBox(height: 105, child: _PanelMessage('添加自选后查看走势'))
              : LayoutBuilder(
                  builder: (context, layout) {
                    final columns = layout.maxWidth >= 408
                        ? securities.length
                        : 1;
                    final width =
                        (layout.maxWidth - (columns - 1) * 8) / columns;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final security in securities)
                          SizedBox(width: width, child: _tile(security)),
                      ],
                    );
                  },
                ),
        ),
      ],
    ),
  );

  Widget _tile(Security security) {
    final bars = daily(security)?.bars ?? const <MarketBar>[];
    final last = bars.lastOrNull;
    final change = last == null ? null : QuoteChange.fromBars(bars, last);
    final color = changeColor(change?.value);
    return Material(
      color: terminalSurface,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: () => onSelect(security),
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                security.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(
                last == null
                    ? '—'
                    : '${last.close}${change == null ? '' : '  ${signed(change.percent)}%'}',
                style: numericStyle.copyWith(
                  color: last == null ? terminalMuted : color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 28,
                width: double.infinity,
                child: bars.length < 2
                    ? Text(
                        security.code,
                        style: numericStyle.copyWith(
                          color: terminalMuted,
                          fontSize: 11,
                        ),
                      )
                    : MarketSparkline(bars, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DataPanel extends StatelessWidget {
  const DataPanel({
    required this.snapshot,
    required this.selectedDay,
    super.key,
  });

  final MarketSnapshot? snapshot;
  final String selectedDay;

  @override
  Widget build(BuildContext context) {
    final current = snapshot;
    final coverage = current?.coverage;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _PanelHeading(title: '行情数据'),
          _dataRow('查询日期', '$selectedDay · 北京时间'),
          _dataRow(
            '数据来源',
            current == null
                ? '—'
                : '${current.source} · 未复权${current.status == 'cached' ? ' · 缓存' : ''}',
          ),
          _dataRow(
            coverage == null ? '行情时间' : '分钟覆盖',
            coverage == null
                ? (current?.bars.lastOrNull?.time ?? '—')
                : '${coverage.expected - coverage.missing}/${coverage.expected} · 15:00 ${coverage.hasClosingBar ? '有记录' : '缺记录'}',
          ),
          if (current != null) _dataRow('抓取时间', marketTime(current.fetchedAt)),
          if (current?.reason case final String reason)
            _dataRow('刷新状态', '使用缓存（$reason）'),
          const SizedBox(height: 9),
        ],
      ),
    );
  }

  Widget _dataRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
    child: Row(
      children: [
        Text(label, style: const TextStyle(color: terminalMuted, fontSize: 12)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            style: numericStyle.copyWith(fontSize: 12),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

String marketTime(String value) => value.length >= 16
    ? '${value.substring(0, 10)} ${value.substring(11, 16)}'
    : value;

class SecuritySearch extends StatefulWidget {
  const SecuritySearch({
    required this.onSearch,
    required this.loading,
    required this.message,
    required this.matches,
    required this.onSelect,
    super.key,
  });

  final ValueChanged<String> onSearch;
  final bool loading;
  final String? message;
  final List<Security> matches;
  final ValueChanged<Security> onSelect;

  @override
  State<SecuritySearch> createState() => _SecuritySearchState();
}

class _SecuritySearchState extends State<SecuritySearch> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();

  void _search() {
    if (_form.currentState!.validate()) {
      widget.onSearch(_code.text.trim());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PanelHeading(title: '股票查询'),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Form(
            key: _form,
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 350,
                  child: TextFormField(
                    controller: _code,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '证券名称或代码',
                      hintText: '简称、六位代码或 920445.BJ',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final input = value?.trim() ?? '';
                      return input.isEmpty || input.length > 32
                          ? '请输入证券简称或代码'
                          : null;
                    },
                    onFieldSubmitted: (_) => _search(),
                  ),
                ),
                FilledButton(onPressed: _search, child: const Text('查询')),
              ],
            ),
          ),
        ),
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.message case final String message)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Text(message, style: const TextStyle(color: terminalMuted)),
          ),
        if (widget.matches.isNotEmpty)
          SizedBox(
            height: (widget.matches.length.clamp(1, 5) * 48).toDouble(),
            child: ListView.builder(
              itemCount: widget.matches.length,
              itemExtent: 48,
              itemBuilder: (context, index) {
                final match = widget.matches[index];
                return ListTile(
                  dense: true,
                  title: Text(match.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(match.code, style: numericStyle),
                  trailing: Text(
                    match.board,
                    style: const TextStyle(color: terminalMuted),
                  ),
                  onTap: () => widget.onSelect(match),
                );
              },
            ),
          ),
      ],
    ),
  );
}

class SecurityDialog extends StatefulWidget {
  const SecurityDialog({super.key});

  @override
  State<SecurityDialog> createState() => _SecurityDialogState();
}

class _SecurityDialogState extends State<SecurityDialog> {
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, Security.parse(_code.text));
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加自选'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _code,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '沪深北 A 股证券代码',
          hintText: '例如 600519、300033.SZ 或 920445.BJ',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        validator: (value) =>
            Security.parse(value ?? '') == null ? '请输入有效的沪深北 A 股证券代码' : null,
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('添加')),
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: terminalPanel,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: terminalBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _PanelHeading extends StatelessWidget {
  const _PanelHeading({required this.title, this.actions = const []});
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    height: 47,
    padding: const EdgeInsets.fromLTRB(14, 0, 7, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ),
        ...actions,
      ],
    ),
  );
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.selected,
    required this.onSelect,
  });
  final Map<String, String> tabs;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => Container(
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: const BoxDecoration(
      color: terminalHeader,
      border: Border(
        top: BorderSide(color: terminalBorder),
        bottom: BorderSide(color: terminalBorder),
      ),
    ),
    child: Row(
      children: [
        for (final tab in tabs.entries)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected == tab.key
                      ? terminalBlue
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: TextButton(
              onPressed: () => onSelect(tab.key),
              style: TextButton.styleFrom(
                foregroundColor: selected == tab.key
                    ? terminalText
                    : terminalMuted,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                tab.value,
                style: TextStyle(
                  fontWeight: selected == tab.key
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _PanelMessage extends StatelessWidget {
  const _PanelMessage(this.message, {this.onRetry, this.actionLabel = '重试'});
  final String message;
  final VoidCallback? onRetry;
  final String actionLabel;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: terminalMuted),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: Text(actionLabel)),
        ],
      ),
    ),
  );
}
