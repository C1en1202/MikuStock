import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'market_data.dart';

String gatewayErrorMessage(String code) => switch (code) {
  'connection' => '行情源连接失败，请稍后重试或检查网络与代理设置',
  'proxy_error' => '无法连接配置的代理，请检查代理是否正在运行',
  'timeout' => '行情源响应超时，请稍后重试',
  'tls_error' => '行情源证书校验失败，请检查系统时间及网络环境',
  'rate_limited' => '行情源暂时限流，请稍后再试',
  'server_error' => '行情源服务暂时不可用，请稍后重试',
  'http_error' => '行情源拒绝了请求，请稍后重试',
  'invalid_data' || 'invalid_response' => '行情源返回的数据暂时无法解析，请重试',
  'worker_failed' => '行情读取进程异常，请重试',
  'gateway_error' => '内置行情服务处理失败，请重试并查看网关日志',
  _ => code,
};

class GatewayDisconnected extends GatewayException {
  const GatewayDisconnected([String? reason])
    : super(reason ?? '内置行情网关已退出，自动恢复未成功，请重试；详细原因见 gateway.log');
}

class GatewayDiagnostics {
  GatewayDiagnostics(this.file);

  final File file;
  Future<void> _writes = Future.value();

  Future<void> flush() => _writes;

  void record(String message) {
    final entry =
        '${DateTime.now().toUtc().toIso8601String()} client=$pid $message\n';
    _writes = _writes
        .then((_) async {
          await file.parent.create(recursive: true);
          // Keep a bounded local log. Request payloads are never logged.
          final mode = await file.exists() && await file.length() > 256 * 1024
              ? FileMode.write
              : FileMode.append;
          await file.writeAsString(entry, mode: mode, flush: true);
        })
        .catchError((Object _) {});
  }
}

class GatewayClient {
  GatewayClient(this._open);

  final Future<GatewayConnection> Function() _open;
  Future<GatewayConnection>? _connection;
  bool _closed = false;

  static const _recoverable = {
    'health',
    'bars',
    'preferences',
    'stock_names',
    'stock_search',
    'paper_account',
    'paper_quote',
  };

  Future<Object?> request(
    String operation,
    Map<String, Object?> payload,
  ) async {
    for (var attempt = 0; ; attempt++) {
      if (_closed) throw const GatewayException('行情网关已关闭');
      final opening = _connection ??= _open();
      try {
        final connection = await opening;
        if (_closed) {
          connection.close();
          throw const GatewayException('行情网关已关闭');
        }
        return await connection.request(operation, payload);
      } catch (error) {
        if (identical(_connection, opening)) {
          final connection = await opening.then<GatewayConnection?>(
            (value) => value,
            onError: (Object _) => null,
          );
          if (identical(_connection, opening) &&
              (connection == null || connection.isClosed)) {
            _connection = null;
          }
        }
        // Trading writes may already have committed when their reply is lost.
        // Only replay reads, once, and let the UI reconcile unconfirmed writes.
        if (!_closed &&
            attempt == 0 &&
            error is GatewayDisconnected &&
            _recoverable.contains(operation)) {
          continue;
        }
        rethrow;
      }
    }
  }

  void close() {
    _closed = true;
    unawaited(
      _connection?.then((value) => value.close(), onError: (Object _) {}),
    );
  }
}

class GatewayConnection {
  GatewayConnection(this._process, {void Function(String)? log})
    : _log = log ?? _discard {
    _process.stdin.encoding = utf8;
    _process.stdin.done.then<void>(
      (_) {},
      onError: (Object error) {
        _disconnect('stdin error: ${error.runtimeType}');
      },
    );
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _readError,
          onError: (Object error) => _log('stderr error: ${error.runtimeType}'),
        );
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _read,
          onError: (Object error) =>
              _disconnect('stdout error: ${error.runtimeType}'),
          onDone: () => _disconnect('stdout closed'),
        );
    _process.exitCode.then((code) {
      _log('gateway pid=${_process.pid} exited code=$code');
      _disconnect('process exited');
    });
    _log('gateway pid=${_process.pid} started');
  }

  static void _discard(String _) {}

  final Process _process;
  final void Function(String) _log;
  final _requests = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool isClosed = false;
  String? _failureHint;

  void _readError(String line) {
    _log('stderr: ${line.length > 2048 ? line.substring(0, 2048) : line}');
    if (line.contains('ModuleNotFoundError') || line.contains('ImportError')) {
      _failureHint = '内置行情网关缺少依赖，请重新构建完整程序；详情见 gateway.log';
    } else if (line.contains('database is locked')) {
      _failureHint = '本地数据库被占用，请关闭多余的客户端后重试；详情见 gateway.log';
    } else if (line.contains('PermissionError') ||
        line.contains('unable to open database file') ||
        line.contains('readonly database')) {
      _failureHint = '无法访问本地数据目录，请检查目录权限；详情见 gateway.log';
    }
  }

  Future<Object?> request(
    String operation,
    Map<String, Object?> payload,
  ) async {
    if (isClosed) throw GatewayDisconnected(_failureHint);
    final id = _nextId++;
    final completer = _requests[id] = Completer<Object?>();
    final response = completer.future.timeout(const Duration(minutes: 5));
    try {
      _process.stdin.writeln(
        jsonEncode({'id': id, 'operation': operation, ...payload}),
      );
      return await response;
    } on StateError {
      response.ignore();
      _disconnect('request pipe closed');
      throw const GatewayDisconnected();
    } on TimeoutException {
      _log('request timed out: operation=$operation');
      throw const GatewayException('内置行情服务响应超时，请重试');
    } finally {
      _requests.remove(id);
    }
  }

  void _read(String line) {
    if (line.trim().isEmpty) return;
    final Object? response;
    try {
      response = jsonDecode(line);
    } on FormatException {
      // A diagnostic printed to stdout must not terminate the whole gateway.
      _log('ignored non-JSON stdout line');
      return;
    }
    if (response is! Map<String, dynamic> || response['id'] is! int) return;
    final request = _requests.remove(response['id']);
    if (request == null) return;
    if (response['error'] case final String error) {
      _log('request rejected: code=$error');
      request.completeError(
        GatewayException(
          response['detail'] as String? ?? gatewayErrorMessage(error),
        ),
      );
    } else {
      request.complete(response['result']);
    }
  }

  void _disconnect(String reason) {
    if (isClosed) return;
    isClosed = true;
    _log('gateway disconnected: $reason');
    _process.stdin.close().ignore();
    for (final request in _requests.values) {
      request.completeError(GatewayDisconnected(_failureHint));
    }
    _requests.clear();
  }

  void close() {
    _disconnect('client closed');
    _process.kill();
  }
}
