import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'market_data.dart';
import 'paper_trading.dart';

enum MarketRead { cacheOnly, preferCache, refresh }

class MarketGateway {
  Future<_GatewayConnection>? _connection;
  bool _closed = false;

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

  Future<Object?> _request(
    String operation,
    Map<String, Object?> payload,
  ) async {
    if (_closed) throw const GatewayException('行情网关已关闭');
    final opening = _connection ??= _start();
    try {
      return await (await opening).request(operation, payload);
    } catch (_) {
      if (identical(_connection, opening)) {
        final connection = await opening.then<_GatewayConnection?>(
          (value) => value,
          onError: (Object _) => null,
        );
        if (connection == null || connection.isClosed) _connection = null;
      }
      rethrow;
    }
  }

  Future<_GatewayConnection> _start() async {
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
    final legacy = _findLegacyDatabase(app);
    final process = await Process.start(python.path, [
      '-B',
      '-m',
      'gateway',
      '--stdio',
      '--db',
      File.fromUri(storage.uri.resolve('market.sqlite3')).path,
      if (legacy != null) ...['--legacy-db', legacy.path],
      if (environment['MIKUSTOCK_USE_PROXY'] != '1') '--direct',
    ], workingDirectory: runtime.path);
    final connection = _GatewayConnection(process);
    await const MethodChannel('mikustock/window')
        .invokeMethod<void>('ownGateway', process.pid)
        .then<void>((_) {}, onError: (Object _) {});
    if (_closed) connection.close();
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
    _closed = true;
    unawaited(
      _connection?.then((value) => value.close(), onError: (Object _) {}),
    );
  }
}

class _GatewayConnection {
  _GatewayConnection(this._process) {
    _process.stdin.done.ignore();
    _process.stderr.drain<void>().ignore();
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_read, onError: (Object _) => close(), onDone: close);
  }

  final Process _process;
  final _requests = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool isClosed = false;

  Future<Object?> request(
    String operation,
    Map<String, Object?> payload,
  ) async {
    if (isClosed) throw const GatewayException('内置行情网关已退出');
    final id = _nextId++;
    final completer = _requests[id] = Completer<Object?>();
    try {
      _process.stdin.writeln(
        jsonEncode({'id': id, 'operation': operation, ...payload}),
      );
      return await completer.future.timeout(const Duration(minutes: 5));
    } finally {
      _requests.remove(id);
    }
  }

  void _read(String line) {
    final Object? response;
    try {
      response = jsonDecode(line);
    } on FormatException {
      close();
      return;
    }
    if (response is! Map<String, dynamic>) return;
    final request = _requests.remove(response['id']);
    if (request == null) return;
    if (response['error'] case final String error) {
      request.completeError(
        GatewayException(response['detail'] as String? ?? error),
      );
    } else {
      request.complete(response['result']);
    }
  }

  void close() {
    if (isClosed) return;
    isClosed = true;
    _process.stdin.close().ignore();
    for (final request in _requests.values) {
      request.completeError(const GatewayException('内置行情网关已退出'));
    }
    _requests.clear();
  }
}
