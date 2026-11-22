import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'market_data.dart';
import 'market_gateway.dart';
import 'module_transition.dart';
import 'terminal_panels.dart';
import 'terminal_theme.dart';
import 'trade_page.dart';

void main() => runApp(const MikuStock());

class MikuStock extends StatelessWidget {
  const MikuStock({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MikuStock',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      colorScheme: const ColorScheme.dark(
        primary: terminalBlue,
        surface: terminalPanel,
        surfaceContainerHigh: terminalSurface,
        onSurface: terminalText,
        onSurfaceVariant: terminalMuted,
        outline: terminalBorder,
        error: terminalRed,
      ),
      scaffoldBackgroundColor: terminalBackground,
      dividerColor: terminalBorder,
      fontFamily: 'Microsoft YaHei UI',
    ),
    home: const _Terminal(),
  );
}

const _defaultWatchlist = [
  'sz000001',
  'sh600519',
  'sz000858',
  'sh600036',
  'sh601318',
];

typedef _Query = ({String symbol, String interval, String day});
typedef _PendingQuery = ({MarketRead mode, Future<void> future});

class _Terminal extends StatefulWidget {
  const _Terminal();

  @override
  State<_Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<_Terminal> {
  final _gateway = MarketGateway();
  final _watchlist = [..._defaultWatchlist];
  final _stockNames = <String, Security>{};
  final _pendingNames = <String>{};
  final _snapshots = <_Query, MarketSnapshot>{};
  final _errors = <_Query, String>{};
  final _pending = <_Query, _PendingQuery>{};
  String _selected = _defaultWatchlist.first;
  DateTime _day = _today;
  String _interval = '1m';
  String _exchange = '全部';
  TerminalPage _section = TerminalPage.watchlist;
  bool _restoring = true;
  bool _searchResult = false;
  bool _searching = false;
  int _searchRevision = 0;
  List<Security> _matches = [];
  String? _searchMessage;
  bool _refreshing = false;

  static DateTime get _today {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(now.year, now.month, now.day);
  }

  _Query _query(String symbol, String interval, [DateTime? day]) =>
      (symbol: symbol, interval: interval, day: dateKey(day ?? _day));

  MarketSnapshot? _snapshot(String symbol, String interval) =>
      _snapshots[_query(symbol, interval)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_restore());
    });
  }

  Future<void> _restore() async {
    try {
      final settings = await _gateway.preferences();
      if (!mounted) return;
      setState(() {
        if (settings['watchlist'] case final List<dynamic> saved) {
          _watchlist
            ..clear()
            ..addAll(
              saved.whereType<String>().map(Security.parse).nonNulls.toSet(),
            );
        }
        if (settings['selected'] case final String value) {
          final code = Security.parse(value);
          if (code != null) _selected = code;
        }
        if (settings['day'] case final String value) {
          final day = DateTime.tryParse(value);
          if (day != null && day.year >= 1991 && !day.isAfter(_today)) {
            _day = day;
          }
        }
        if (settings['interval'] == '1d') _interval = '1d';
        _section =
            TerminalPage.values
                .where((page) => page.name == settings['page'])
                .firstOrNull ??
            TerminalPage.watchlist;
        _searchResult = _section == TerminalPage.search;
      });
    } catch (_) {
      // The selected panel will report gateway errors when it reads the cache.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
    if (mounted) await Future.wait([_restoreCachedQuotes(), _restoreNames()]);
  }

  Future<void> _restoreNames() async {
    try {
      final names = await _gateway.stockNames([_selected, ..._watchlist]);
      if (mounted) {
        setState(
          () => _stockNames.addEntries(
            names
                .where((item) => !_stockNames.containsKey(item.symbol))
                .map((item) => MapEntry(item.symbol, item)),
          ),
        );
      }
    } catch (_) {
      // The cache can be unavailable while the price panels recover independently.
    }
  }

  Future<void> _restoreCachedQuotes() async {
    final day = _day;
    await Future.wait([
      _loadSelection(mode: MarketRead.cacheOnly),
      for (final symbol in _watchlist)
        _load(symbol, '1d', day, mode: MarketRead.cacheOnly),
    ]);
  }

  void _savePreferences() {
    if (_restoring) return;
    _gateway.savePreferences({
      'watchlist': _watchlist.toList(),
      'selected': _selected,
      'day': dateKey(_day),
      'interval': _interval,
      'page': _section.name,
    }).ignore();
  }

  Future<void> _loadSelection({
    MarketRead mode = MarketRead.preferCache,
  }) async {
    final symbol = _selected;
    final interval = _interval;
    final day = _day;
    if (mode == MarketRead.refresh) unawaited(_resolveName(symbol));
    await _load(symbol, interval, day, mode: mode);
    if (mounted && interval == '1m' && day == _day && symbol == _selected) {
      await _load(
        symbol,
        '1d',
        day,
        mode: mode == MarketRead.refresh ? MarketRead.preferCache : mode,
      );
    }
  }

  Future<void> _load(
    String symbol,
    String interval,
    DateTime day, {
    required MarketRead mode,
  }) async {
    final key = _query(symbol, interval, day);
    if (_pending[key] case final _PendingQuery pending) {
      await pending.future;
      if (mounted &&
          day == _day &&
          pending.mode == MarketRead.cacheOnly &&
          mode != MarketRead.cacheOnly) {
        await _load(symbol, interval, day, mode: mode);
      }
      return;
    }
    if (mode != MarketRead.refresh && _snapshots.containsKey(key)) return;
    final request = _fetch(key, day, mode);
    setState(() => _pending[key] = (mode: mode, future: request));
    await request;
  }

  Future<void> _fetch(_Query key, DateTime day, MarketRead mode) async {
    try {
      final snapshot = await _gateway.bars(
        symbol: key.symbol,
        interval: key.interval,
        day: day,
        mode: mode,
      );
      if (mounted && day == _day) {
        if (snapshot != null) _snapshots[key] = snapshot;
        _errors.remove(key);
      }
    } on GatewayException catch (error) {
      if (mounted && day == _day) _errors[key] = '行情读取失败（${error.message}）';
    } catch (_) {
      if (mounted && day == _day) _errors[key] = '内置行情服务读取失败，请重试。';
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  Future<void> _refreshWatchlist() async {
    if (_refreshing) return;
    final day = _day;
    final symbols = _watchlist
        .where(
          (symbol) =>
              _exchange == '全部' || _securityFor(symbol).exchange == _exchange,
        )
        .toList();
    setState(() => _refreshing = true);
    try {
      for (final symbol in symbols) {
        if (!mounted || _day != day) break;
        await Future.wait([
          _resolveName(symbol),
          _load(symbol, '1d', day, mode: MarketRead.refresh),
        ]);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _select(String symbol, TerminalPage page, {bool lookupName = true}) {
    setState(() {
      _selected = symbol;
      _section = page;
      if (page == TerminalPage.search) _searchResult = true;
    });
    _savePreferences();
    unawaited(_loadSelection());
    if (lookupName) unawaited(_resolveName(symbol));
  }

  Future<void> _resolveName(String symbol) async {
    if (_stockNames.containsKey(symbol) || !_pendingNames.add(symbol)) return;
    try {
      final result = await _gateway.search(symbol);
      if (mounted) setState(() => _rememberNames(result.matches));
    } catch (_) {
      // A stock can still load price data when its current name is unavailable.
    } finally {
      _pendingNames.remove(symbol);
    }
  }

  void _rememberNames(Iterable<Security> names) {
    _stockNames.addEntries(names.map((item) => MapEntry(item.symbol, item)));
  }

  Future<void> _search(String keyword) async {
    final revision = ++_searchRevision;
    final exact = Security.parse(keyword);
    setState(() {
      _searching = true;
      _searchResult = false;
      _matches = [];
      _searchMessage = null;
    });
    if (exact != null) _select(exact, TerminalPage.search, lookupName: false);
    try {
      final result = await _gateway.search(keyword);
      if (!mounted || revision != _searchRevision) return;
      setState(() {
        _rememberNames(result.matches);
        if (exact == null) _matches = result.matches;
        if (result.incomplete) {
          _searchMessage = '部分证券目录暂时不可用';
        } else if (result.matches.isEmpty) {
          _searchMessage = exact == null ? '未找到匹配的证券' : '暂未取得证券简称，可继续按代码查询行情';
        }
      });
      if (exact == null && _section == TerminalPage.search) {
        final exactNames = result.matches
            .where((item) => item.name == keyword)
            .toList();
        if (exactNames.length == 1) {
          _select(
            exactNames.single.symbol,
            TerminalPage.search,
            lookupName: false,
          );
        }
      }
    } catch (_) {
      if (mounted && revision == _searchRevision) {
        setState(() => _searchMessage = '证券目录读取失败，请重试');
      }
    } finally {
      if (mounted && revision == _searchRevision) {
        setState(() => _searching = false);
      }
    }
  }

  void _selectInterval(String interval) {
    if (_interval == interval) return;
    setState(() => _interval = interval);
    _savePreferences();
    unawaited(_loadSelection());
  }

  void _navigate(TerminalPage section) {
    setState(() => _section = section);
    _savePreferences();
  }

  Future<void> _pickDate() async {
    if (_restoring) return;
    final day = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(1991),
      lastDate: _today,
      helpText: '选择行情日期',
    );
    if (!mounted || day == null || day == _day) return;
    setState(() {
      _day = day;
      _snapshots.clear();
      _errors.clear();
    });
    _savePreferences();
    await _restoreCachedQuotes();
  }

  Security _securityFor(String code) => _stockNames[code] ?? Security(code);

  Future<void> _addSecurity() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const SecurityDialog(),
    );
    if (!mounted || code == null) return;
    if (!_watchlist.contains(code)) {
      setState(() {
        _watchlist.add(code);
        _exchange = '全部';
      });
    }
    _select(code, TerminalPage.market);
  }

  void _toggleFavorite() {
    setState(() {
      final index = _watchlist.indexOf(_selected);
      if (index < 0) {
        _watchlist.add(_selected);
        _exchange = '全部';
      } else {
        _watchlist.removeAt(index);
      }
    });
    _savePreferences();
  }

  @override
  void dispose() {
    _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _securityFor(_selected);
    final currentKey = _query(_selected, _interval);
    final current = _snapshots[currentKey];
    final selectedDaily = _snapshot(_selected, '1d');
    final visibleWatchlist = _watchlist
        .map(_securityFor)
        .where((item) => _exchange == '全部' || item.exchange == _exchange)
        .toList();
    MarketSnapshot? daily(Security item) => _snapshot(item.symbol, '1d');
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, window) {
          final compact = window.maxWidth < 1100;
          final sidebarWidth = compact ? 64.0 : 148.0;
          final wide = window.maxWidth - sidebarWidth >= 890;
          final watchlist = WatchlistPanel(
            securities: visibleWatchlist,
            selected: selected,
            exchange: _exchange,
            onExchange: (value) => setState(() => _exchange = value),
            onSelect: (security) =>
                _select(security.symbol, TerminalPage.market),
            onAdd: _addSecurity,
            onRefresh: _refreshing ? null : _refreshWatchlist,
            daily: daily,
          );
          final quote = QuotePanel(
            security: selected,
            interval: _interval,
            snapshot: current,
            daily: selectedDaily,
            loading: _pending.containsKey(currentKey),
            error: _errors[currentKey],
            favorite: _watchlist.contains(_selected),
            onFavorite: _toggleFavorite,
            onInterval: _selectInterval,
            onRefresh: () => _loadSelection(mode: MarketRead.refresh),
            onTrade: () => _navigate(TerminalPage.trade),
          );
          final overview = OverviewPanel(
            securities: _watchlist.take(3).map(_securityFor).toList(),
            daily: daily,
            onSelect: (security) =>
                _select(security.symbol, TerminalPage.market),
          );
          final status = DataPanel(
            snapshot: current,
            selectedDay: dateKey(_day),
          );
          Widget pair(Widget first, Widget second) => wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 70, child: first),
                    const SizedBox(width: 12),
                    Expanded(flex: 30, child: second),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [first, const SizedBox(height: 12), second],
                );
          final Widget page = switch (_section) {
            TerminalPage.watchlist => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [watchlist, const SizedBox(height: 12), overview],
            ),
            TerminalPage.trade => TradePage(
              gateway: _gateway,
              day: _day,
              security: selected,
              securityFor: _securityFor,
            ),
            TerminalPage.search => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SecuritySearch(
                  onSearch: _search,
                  loading: _searching,
                  message: _searchMessage,
                  matches: _matches,
                  onSelect: (security) => _select(
                    security.symbol,
                    TerminalPage.search,
                    lookupName: false,
                  ),
                ),
                if (_searchResult) ...[
                  const SizedBox(height: 12),
                  pair(quote, status),
                ],
              ],
            ),
            TerminalPage.market => pair(quote, status),
          };
          return Column(
            children: [
              TerminalHeader(
                date: dateKey(_day),
                onDate: _pickDate,
                onSearch: () => _navigate(TerminalPage.search),
                onRefresh: _pending.containsKey(currentKey) || _restoring
                    ? null
                    : () => _loadSelection(mode: MarketRead.refresh),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: sidebarWidth,
                      child: TerminalSidebar(
                        compact: compact,
                        section: _section,
                        onSelect: _navigate,
                      ),
                    ),
                    Expanded(
                      child: _restoring
                          ? const Center(child: CircularProgressIndicator())
                          : ModuleTransition(
                              module: _section,
                              child: ListView(
                                key: ValueKey(_section),
                                padding: const EdgeInsets.all(12),
                                children: [page],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
