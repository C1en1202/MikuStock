class PaperQuote {
  PaperQuote.fromJson(Map<String, dynamic> json)
    : symbol = json['symbol'] as String,
      day = json['day'] as String,
      price = json['price'] as int;

  final String symbol;
  final String day;
  final int price;
}

class PaperAccount {
  PaperAccount.fromJson(Map<String, dynamic> json)
    : id = json['account_id'] as String,
      initialCash = json['initial_cash'] as int,
      cash = json['cash'] as int,
      realized = json['realized'] as int,
      lastDay = json['last_day'] as String?,
      asOf = json['as_of'] as String,
      marketValue = json['market_value'] as int,
      equity = json['equity'] as int,
      profit = json['profit'] as int,
      tradeCount = json['trade_count'] as int,
      positions = (json['positions'] as List)
          .map((item) => PaperPosition.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      trades = (json['trades'] as List)
          .map((item) => PaperTrade.fromJson(item as Map<String, dynamic>))
          .toList(growable: false);

  final String id;
  final int initialCash;
  final int cash;
  final int realized;
  final String? lastDay;
  final String asOf;
  final int marketValue;
  final int equity;
  final int profit;
  final int tradeCount;
  final List<PaperPosition> positions;
  final List<PaperTrade> trades;
}

class PaperPosition {
  PaperPosition.fromJson(Map<String, dynamic> json)
    : symbol = json['symbol'] as String,
      quantity = json['quantity'] as int,
      available = json['available'] as int,
      cost = json['cost'] as int,
      price = json['price'] as int?,
      priceDay = json['price_day'] as String?,
      marketValue = json['market_value'] as int,
      unrealized = json['unrealized'] as int;

  final String symbol;
  final int quantity;
  final int available;
  final int cost;
  final int? price;
  final String? priceDay;
  final int marketValue;
  final int unrealized;
}

class PaperTrade {
  PaperTrade.fromJson(Map<String, dynamic> json)
    : id = json['id'] as int,
      symbol = json['symbol'] as String,
      side = json['side'] as String,
      day = json['day'] as String,
      quantity = json['quantity'] as int,
      price = json['price'] as int,
      amount = json['amount'] as int,
      commission = json['commission'] as int,
      stamp = json['stamp'] as int,
      realized = json['realized'] as int;

  final int id;
  final String symbol;
  final String side;
  final String day;
  final int quantity;
  final int price;
  final int amount;
  final int commission;
  final int stamp;
  final int realized;
}

int paperCommission(int amount) =>
    ((amount * 3 + 5000) ~/ 10000).clamp(500, 1 << 62);
int paperStamp(int amount) => (amount * 5 + 5000) ~/ 10000;
String paperMoney(num cents) => (cents / 100).toStringAsFixed(2);
