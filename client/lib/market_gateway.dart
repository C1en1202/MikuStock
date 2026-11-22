import 'dart:io';

import 'package:flutter/services.dart';

import 'market_data.dart';
import 'gateway_transport.dart';
import 'paper_trading.dart';

enum MarketRead { cacheOnly, preferCache, refresh }

class MarketGateway {
  late final _transport = GatewayClient(_start);
  GatewayDiagnostics? _diagnostics;

  Future<MarketSnapshot?> bars({
    required String symbol,
    required String interval,
    required DateTime day,
    required MarketRead mode,
  }) async {
    final end = dateKey(day);
    final start = interval == '1m'
        ? end
        : dateKey(DateTime(day.year, day.month, day.day - 45));
    final result = await _request('bars', {
      'symbol': symbol,
      'interval': interval,
      'start': start,
      'end': end,
      'mode': switch (mode) {
        MarketRead.cacheOnly => 'cache_only',
        MarketRead.preferCache => 'prefer_cache',
        MarketRead.refresh => 'refresh',
      },
    });
    if (result == null) return null;
    final json = result as Map<String, dynamic>;
    if (json['version'] != 1) throw const GatewayException('行情网关版本不兼容');
    return MarketSnapshot.fromJson(json);
  }

  Future<Map<String, dynamic>> preferences() async =>
      await _request('preferences', {}) as Map<String, dynamic>;

  Future<List<Security>> stockNames(Iterable<String> symbols) async =>
      decodeSecurities(
        await _request('stock_names', {'symbols': symbols.toList()}),
      );

  Future<SecuritySearchResult> search(String keyword) async =>
      SecuritySearchResult.fromJson(
        await _request('stock_search', {'keyword': keyword})
            as Map<String, dynamic>,
      );

  Future<void> savePreferences(Map<String, Object?> value) async {
    await _request('save_preferences', {'value': value});
  }

  Future<PaperAccount> paperAccount(String day) async => PaperAccount.fromJson(
    await _request('paper_account', {'day': day}) as Map<String, dynamic>,
  );

  Future<PaperQuote> paperQuote(String symbol, String day) async =>
      PaperQuote.fromJson(
        await _request('paper_quote', {'symbol': symbol, 'day': day})
            as Map<String, dynamic>,
      );

  Future<PaperAccount> paperOrder({
    required String accountId,
    required String requestId,
    required PaperQuote quote,
    required String side,
    required int quantity,
  }) async => PaperAccount.fromJson(
    await _request('paper_order', {
      'account_id': accountId,
      'request_id': requestId,
      'symbol': quote.symbol,
      'day': quote.day,
      'price': quote.price,
      'side': side,
      'quantity': quantity,
    }) as Map<String, dynamic>,
  );

  Future<PaperAccount> resetPaperAccount(String accountId, String day) async =>
      PaperAccount.fromJson(
        await _request('paper_reset', {'account_id': accountId, 'day': day})
            as Map<String, dynamic>,
      );

  Future<PaperAccount> paperLimitOrder({
    required String accountId,
    required String requestId,
    required PaperQuote quote,
    required String side,
    required int quantity,
    required int limitPrice,
  }) async => PaperAccount.fromJson(
    await _request('paper_limit_order', {
      'account_id': accountId,
      'request_id': requestId,
      'symbol': quote.symbol,
      'day': quote.day,
      'side': side,
      'quantity': quantity,
      'limit_price': limitPrice,
    }) as Map<String, dynamic>,
  );

  Future<PaperAccount> cancelPaperOrder(
    String accountId,
    int orderId,
    String day,
  ) async => PaperAccount.fromJson(
    await _request('paper_cancel_order', {
      'account_id': accountId,
      'order_id': orderId,
      'day': day,
    }) as Map<String, dynamic>,
  );

  Future<PaperAccount> matchPaperOrders(String accountId, String day) async =>
      PaperAccount.fromJson(
        await _request('paper_match_orders', {
          'account_id': accountId,
          'day': day,
        }) as Map<String, dynamic>,
      );

  Future<Object?> _request(String operation, Map<String, Object?> payload) =>
      _transport.request(operation, payload);

  Future<GatewayConnection> _start() async {
    final environment = Platform.environment;
    final app = File(Platform.resolvedExecutable).parent;
    final runtime = Directory.fromUri(app.uri.resolve('gateway-runtime/'));
    final python = File.fromUri(runtime.uri.resolve('python.exe'));
    if (!python.existsSync()) throw const GatewayException('程序目录缺少内置行情网关');
    final localData = environment['LOCALAPPDATA'] ?? environment['APPDATA'];
    final Directory storage;
    if (environment['MIKUSTOCK_DATA_DIR'] case final String path) {
      storage = Directory(path).absolute;
    } else if (localData != null) {
      storage = Directory.fromUri(
        Directory(localData).uri.resolve('MikuStock/'),
      );
    } else {
      throw const GatewayException('Windows 本地应用数据目录不可用');
    }
    final diagnostics = _diagnostics ??= GatewayDiagnostics(
      File.fromUri(storage.uri.resolve('gateway.log')),
    );
    final legacy = _findLegacyDatabase(app);
    final Process process;
    try {
      process = await Process.start(
        python.path,
        [
          '-B',
          '-m',
          'gateway',
          '--stdio',
          '--db',
          File.fromUri(storage.uri.resolve('market.sqlite3')).path,
          if (legacy != null) ...['--legacy-db', legacy.path],
          if (environment['MIKUSTOCK_USE_PROXY'] != '1') '--direct',
        ],
        workingDirectory: runtime.path,
        environment: {
          'PYTHONUTF8': '1',
          'PYTHONIOENCODING': 'utf-8',
          'PYTHONUNBUFFERED': '1',
        },
      );
    } on ProcessException catch (error) {
      diagnostics.record('gateway launch failed: OS error=${error.errorCode}');
      throw const GatewayException('无法启动内置行情网关，请检查程序目录是否完整；详情见 gateway.log');
    }
    final connection = GatewayConnection(process, log: diagnostics.record);
    await const MethodChannel('mikustock/window')
        .invokeMethod<void>('ownGateway', process.pid)
        .then<void>((_) {}, onError: (Object _) {});
    return connection;
  }

  File? _findLegacyDatabase(Directory directory) {
    while (directory.parent.path != directory.path) {
      if (File.fromUri(directory.uri.resolve('gateway/__main__.py'))
          .existsSync()) {
        final database = File.fromUri(
          directory.uri.resolve('data/market.sqlite3'),
        );
        return database.existsSync() ? database : null;
      }
      directory = directory.parent;
    }
    return null;
  }

  void close() {
    _transport.close();
  }
}
