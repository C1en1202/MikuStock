String dateKey(DateTime day) => day.toIso8601String().substring(0, 10);

class Security {
  const Security(this.symbol, [this.name = '']);

  factory Security.fromJson(Map<String, dynamic> value) =>
      Security(value['symbol'] as String, value['name'] as String);

  final String symbol;
  final String name;

  String get exchange => symbol.substring(0, 2).toUpperCase();
  String get code => '${symbol.substring(2)}.$exchange';
  String get displayName => name.isEmpty ? code : name;

  String get board {
    if (exchange == 'BJ') return '北交所';
    if (symbol.startsWith('sh68')) return '科创板';
    if (symbol.startsWith('sz30')) return '创业板';
    return exchange == 'SH' ? '沪市主板' : '深市主板';
  }

  static String? parse(String text) {
    final value = text.trim().toLowerCase();
    final match = RegExp(r'^(sh|sz|bj)?([0-9]{6})(?:\.(sh|sz|bj))?$')
        .firstMatch(value);
    if (match == null) return null;
    final code = match[2]!;
    final exchange = switch (code.substring(0, 3)) {
      final prefix when prefix.startsWith('00') || prefix.startsWith('30') =>
        'sz',
      final prefix
          when prefix.startsWith('60') || prefix == '688' || prefix == '689' =>
        'sh',
      final prefix
          when prefix == '920' ||
              const [
                '43',
                '44',
                '83',
                '87',
                '88',
              ].contains(prefix.substring(0, 2)) =>
        'bj',
      _ => null,
    };
    if (exchange == null ||
        (match[1] != null && match[1] != exchange) ||
        (match[3] != null && match[3] != exchange)) {
      return null;
    }
    return '$exchange$code';
  }
}

class SecuritySearchResult {
  SecuritySearchResult.fromJson(Map<String, dynamic> value)
    : matches = decodeSecurities(value['matches']),
      incomplete = (value['unavailable'] as List).isNotEmpty;

  final List<Security> matches;
  final bool incomplete;
}

List<Security> decodeSecurities(Object? value) => (value as List)
    .map((item) => Security.fromJson(item as Map<String, dynamic>))
    .toList(growable: false);

class QuoteChange {
  const QuoteChange(this.value, this.percent);

  static QuoteChange? fromBars(List<MarketBar> dailyBars, MarketBar last) {
    final prior = dailyBars.reversed
        .where((bar) => bar.time.compareTo(last.time.substring(0, 10)) < 0)
        .firstOrNull;
    if (prior == null) return null;
    final base = double.parse(prior.close);
    final change = double.parse(last.close) - base;
    return QuoteChange(change, change / base * 100);
  }

  final double value;
  final double percent;
}

class GatewayException implements Exception {
  const GatewayException(this.message);

  final String message;
}

class MarketSnapshot {
  MarketSnapshot.fromJson(Map<String, dynamic> json)
    : symbol = json['symbol'] as String,
      interval = json['interval'] as String,
      status = json['status'] as String,
      source = switch (json['source']) {
        'tencent' => '腾讯',
        'eastmoney' => '东方财富',
        _ => '新浪',
      },
      fetchedAt = json['fetched_at'] as String,
      reason = json['reason'] as String?,
      coverage = switch (json['coverage']) {
        final Map<String, dynamic> value => MinuteCoverage.fromJson(value),
        _ => null,
      },
      bars = (json['bars'] as List)
          .map((value) => MarketBar.fromJson(value as Map<String, dynamic>))
          .toList(growable: false);

  final String symbol;
  final String interval;
  final String status;
  final String source;
  final String fetchedAt;
  final String? reason;
  final MinuteCoverage? coverage;
  final List<MarketBar> bars;
}

class MinuteCoverage {
  MinuteCoverage.fromJson(Map<String, dynamic> json)
    : expected = json['continuous_minutes_expected'] as int,
      missing = (json['continuous_minutes_missing'] as List).length,
      hasClosingBar = json['has_1500_bar'] as bool;

  final int expected;
  final int missing;
  final bool hasClosingBar;
}

class MarketBar {
  MarketBar.fromJson(Map<String, dynamic> json)
    : time = json['time'] as String,
      open = json['open'] as String,
      high = json['high'] as String,
      low = json['low'] as String,
      close = json['close'] as String,
      volume = json['volume_shares'] as int,
      amount = json['amount_cny'] as String;

  final String time;
  final String open;
  final String high;
  final String low;
  final String close;
  final int volume;
  final String amount;
}
