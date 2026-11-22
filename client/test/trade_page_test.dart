import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mikustock/market_data.dart';
import 'package:mikustock/market_gateway.dart';
import 'package:mikustock/paper_trading.dart';
import 'package:mikustock/trade_page.dart';

const day = '2026-11-19';

PaperAccount account({String? lastDay, int available = 0, bool held = false}) =>
    PaperAccount.fromJson({
      'account_id': 'test_account',
      'initial_cash': 100000000,
      'cash': held ? 99899500 : 100000000,
      'realized': 0,
      'last_day': lastDay,
      'as_of': lastDay ?? day,
      'market_value': held ? 100000 : 0,
      'equity': held ? 99999500 : 100000000,
      'profit': held ? -500 : 0,
      'trade_count': held ? 1 : 0,
      'positions': [
        if (held)
          {
            'symbol': 'sz000001',
            'quantity': 100,
            'available': available,
            'cost': 100500,
            'price': 1000,
            'price_day': lastDay ?? day,
            'market_value': 100000,
            'unrealized': -500,
          },
      ],
      'trades': [],
    });

class FakeGateway extends MarketGateway {
  PaperAccount value = account();
  final orderIds = <String>[];
  final quoteDelays = <String, Completer<PaperQuote>>{};
  bool failOrder = false;
  bool failQuote = false;
  int resets = 0;

  @override
  Future<PaperAccount> paperAccount(String day) async => value;

  @override
  Future<PaperQuote> paperQuote(String symbol, String day) async {
    if (failQuote) throw const GatewayException('所选日期没有可成交的日 K 行情');
    if (quoteDelays[day] case final Completer<PaperQuote> delayed) {
      return delayed.future;
    }
    return PaperQuote.fromJson({'symbol': symbol, 'day': day, 'price': 1000});
  }

  @override
  Future<PaperAccount> paperOrder({
    required String accountId,
    required String requestId,
    required PaperQuote quote,
    required String side,
    required int quantity,
  }) async {
    orderIds.add(requestId);
    if (failOrder) throw const GatewayException('连接中断');
    return value = account(lastDay: quote.day, held: true);
  }

  @override
  Future<PaperAccount> resetPaperAccount(String accountId, String day) async {
    resets++;
    return value = account();
  }
}

Future<void> mount(
  WidgetTester tester,
  FakeGateway gateway, {
  String date = day,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TradePage(
            gateway: gateway,
            day: DateTime.parse(date),
            security: const Security('sz000001', '平安银行'),
            securityFor: (symbol) => Security(symbol, '平安银行'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get buyButton => find.widgetWithText(FilledButton, '模拟买入');

void main() {
  testWidgets('loads account and fills an order with a visible result', (
    tester,
  ) async {
    final gateway = FakeGateway();
    await mount(tester, gateway);
    expect(find.text('1000000.00'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(buyButton);
    await tester.tap(buyButton);
    await tester.pumpAndSettle();
    expect(gateway.orderIds, hasLength(1));
    expect(find.textContaining('模拟买入成交：'), findsOneWidget);
    expect(find.text('成交记录 · 1 笔'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid lots and insufficient funds disable order submission', (
    tester,
  ) async {
    final gateway = FakeGateway();
    await mount(tester, gateway);
    final quantity = find.byType(TextField).at(1);
    await tester.enterText(quantity, '101');
    await tester.pump();
    expect(tester.widget<FilledButton>(buyButton).onPressed, isNull);
    await tester.enterText(quantity, '100000000');
    await tester.pump();
    expect(find.text('可用资金不足（含模拟佣金）'), findsOneWidget);
    expect(tester.widget<FilledButton>(buyButton).onPressed, isNull);
    expect(gateway.orderIds, isEmpty);
  });

  testWidgets('missing quote disables submission and reports the reason', (
    tester,
  ) async {
    final gateway = FakeGateway()..failQuote = true;
    await mount(tester, gateway);
    expect(find.text('所选日期没有可成交的日 K 行情'), findsOneWidget);
    expect(tester.widget<FilledButton>(buyButton).onPressed, isNull);
  });

  testWidgets('same-day holdings cannot be sold', (tester) async {
    final gateway = FakeGateway()..value = account(lastDay: day, held: true);
    await mount(tester, gateway);
      await tester.tap(find.text('卖出').first);
    await tester.pumpAndSettle();
    final sell = find.widgetWithText(FilledButton, '模拟卖出');
    expect(tester.widget<FilledButton>(sell).onPressed, isNull);
    expect(find.text('可卖数量不足，当日买入的持仓次日才可卖出'), findsOneWidget);
    expect(gateway.orderIds, isEmpty);
  });

  testWidgets('rewinding the date disables orders', (tester) async {
    final gateway = FakeGateway()
      ..value = account(lastDay: '2026-11-20', held: true);
    await mount(tester, gateway);
    expect(find.textContaining('当前查看日期早于最后成交日'), findsOneWidget);
    expect(tester.widget<FilledButton>(buyButton).onPressed, isNull);
  });

  testWidgets('uncertain failures reuse the same order identifier on retry', (
    tester,
  ) async {
    final gateway = FakeGateway()..failOrder = true;
    await mount(tester, gateway);
    await tester.ensureVisible(buyButton);
    await tester.tap(buyButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('下单未确认：连接中断'), findsOneWidget);
    gateway.failOrder = false;
    await tester.ensureVisible(buyButton);
    await tester.tap(buyButton);
    await tester.pumpAndSettle();
    expect(gateway.orderIds, hasLength(2));
    expect(gateway.orderIds[0], gateway.orderIds[1]);
  });

  testWidgets(
    'reset requires confirmation and cancellation preserves account',
    (tester) async {
      final gateway = FakeGateway()..value = account(lastDay: day, held: true);
      await mount(tester, gateway);
      await tester.tap(find.text('重置账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.resets, 0);
      await tester.tap(find.text('重置账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认重置'));
      await tester.pumpAndSettle();
      expect(gateway.resets, 1);
      expect(find.text('模拟账户已重置'), findsOneWidget);
    },
  );

  testWidgets(
    'a delayed quote from an earlier date cannot replace the new quote',
    (tester) async {
      final gateway = FakeGateway();
      final delayed = Completer<PaperQuote>();
      gateway.quoteDelays[day] = delayed;
      // Do not settle while the first quote is pending.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TradePage(
                gateway: gateway,
                day: DateTime.parse(day),
                security: const Security('sz000001'),
                securityFor: Security.new,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await mount(tester, gateway, date: '2026-11-20');
      delayed.complete(
        PaperQuote.fromJson({'symbol': 'sz000001', 'day': day, 'price': 999}),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2026-11-20 缓存收盘价  ¥10.00'), findsOneWidget);
      expect(find.textContaining('¥9.99'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
