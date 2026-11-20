import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'market_data.dart';
import 'terminal_theme.dart';

class MarketChart extends StatelessWidget {
  const MarketChart(this.bars, {required this.minute, super.key});

  final List<MarketBar> bars;
  final bool minute;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${minute ? '分时' : '日 K'}走势和成交量，共 ${bars.length} 条行情',
    child: CustomPaint(
      size: Size.infinite,
      painter: _ChartPainter(bars, minute),
    ),
  );
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.bars, this.minute);

  final List<MarketBar> bars;
  final bool minute;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 95 || size.height < 100) return;
    final plot = Rect.fromLTRB(48, 8, size.width - 6, size.height - 82);
    final volume = Rect.fromLTRB(
      plot.left,
      plot.bottom + 34,
      plot.right,
      size.height - 9,
    );
    final prices = bars
        .map(
          (bar) => (
            open: double.parse(bar.open),
            high: double.parse(bar.high),
            low: double.parse(bar.low),
            close: double.parse(bar.close),
          ),
        )
        .toList(growable: false);
    final high = prices.map((bar) => bar.high).reduce(math.max);
    final low = prices.map((bar) => bar.low).reduce(math.min);
    final margin = math.max((high - low) * 0.05, 0.01);
    final ceiling = high + margin;
    final floor = low - margin;
    final pitch = plot.width / prices.length;
    double x(int index) => plot.left + pitch * (index + 0.5);
    double y(double value) =>
        plot.top + (ceiling - value) * plot.height / (ceiling - floor);

    final grid = Paint()..color = terminalBorder.withValues(alpha: 0.65);
    for (var row = 0; row <= 4; row++) {
      final value = ceiling - (ceiling - floor) * row / 4;
      final position = y(value);
      canvas.drawLine(
        Offset(plot.left, position),
        Offset(plot.right, position),
        grid,
      );
      _label(
        canvas,
        value.toStringAsFixed(2),
        Offset(plot.left - 5, position - 6),
        align: 1,
      );
    }
    final divisions = size.width >= 340 ? 4 : 2;
    _drawTimeAxis(canvas, plot, x, grid, divisions);

    canvas.save();
    canvas.clipRect(plot);
    if (minute) {
      final closePath = Path();
      final averagePath = Path();
      var tradedShares = 0;
      var tradedAmount = 0.0;
      var hasAverage = false;
      for (final (index, bar) in bars.indexed) {
        final point = Offset(x(index), y(prices[index].close));
        if (index == 0) {
          closePath.moveTo(point.dx, point.dy);
        } else {
          closePath.lineTo(point.dx, point.dy);
        }
        tradedShares += bar.volume;
        tradedAmount += double.parse(bar.amount);
        if (tradedShares > 0) {
          final average = y(tradedAmount / tradedShares);
          if (hasAverage) {
            averagePath.lineTo(point.dx, average);
          } else {
            averagePath.moveTo(point.dx, average);
            hasAverage = true;
          }
        }
      }
      if (bars.length == 1) {
        canvas.drawCircle(
          Offset(x(0), y(prices.first.close)),
          3,
          Paint()..color = terminalBlue,
        );
      } else {
        final fill = Path.from(closePath)
          ..lineTo(x(bars.length - 1), plot.bottom)
          ..lineTo(x(0), plot.bottom)
          ..close();
        canvas.drawPath(
          fill,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                terminalBlue.withValues(alpha: 0.26),
                terminalBlue.withValues(alpha: 0.015),
              ],
            ).createShader(plot),
        );
      }
      canvas.drawPath(closePath, _stroke(terminalBlue, 1.35));
      canvas.drawPath(averagePath, _stroke(terminalGold, 1));
    } else {
      final candleWidth = math.min(math.max(pitch * 0.63, 1.0), 16.0);
      for (final (index, bar) in prices.indexed) {
        final color = bar.close >= bar.open ? terminalRed : terminalGreen;
        final paint = Paint()..color = color;
        final position = x(index);
        canvas.drawLine(
          Offset(position, y(bar.high)),
          Offset(position, y(bar.low)),
          paint,
        );
        final top = y(math.max(bar.open, bar.close));
        final height = math.max((y(bar.open) - y(bar.close)).abs(), 1.0);
        canvas.drawRect(
          Rect.fromLTWH(position - candleWidth / 2, top, candleWidth, height),
          paint,
        );
      }
    }
    canvas.restore();

    canvas.drawLine(volume.bottomLeft, volume.bottomRight, grid);
    _label(canvas, '成交量', Offset(0, volume.top - 2), fontSize: 10);
    final peak = bars.map((bar) => bar.volume).reduce(math.max);
    if (peak > 0) {
      _label(
        canvas,
        compactNumber(peak),
        Offset(volume.left - 5, volume.top + 13),
        align: 1,
        fontSize: 9,
      );
      final width = math.min(math.max(pitch * 0.63, 1.0), 14.0);
      for (final (index, bar) in bars.indexed) {
        final height = volume.height * bar.volume / peak;
        final rising = prices[index].close >= prices[index].open;
        canvas.drawRect(
          Rect.fromLTWH(
            x(index) - width / 2,
            volume.bottom - height,
            width,
            height,
          ),
          Paint()
            ..color = (rising ? terminalRed : terminalGreen).withValues(
              alpha: 0.72,
            ),
        );
      }
    }
  }

  void _drawTimeAxis(
    Canvas canvas,
    Rect plot,
    double Function(int) x,
    Paint grid,
    int divisions,
  ) {
    for (var tick = 0; tick <= divisions; tick++) {
      if (bars.length <= divisions && tick != 0 && tick != divisions) continue;
      if (bars.length == 1 && tick != 0) continue;
      final index = ((bars.length - 1) * tick / divisions).round();
      final point = x(index);
      canvas.drawLine(
        Offset(point, plot.top),
        Offset(point, plot.bottom),
        grid,
      );
      final stamp = bars[index].time;
      _label(
        canvas,
        minute ? stamp.substring(11, 16) : stamp.substring(5, 10),
        Offset(point, plot.bottom + 7),
        align: tick == 0 ? 0 : (tick == divisions ? 1 : 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.minute != minute;
}

class MarketSparkline extends StatelessWidget {
  const MarketSparkline(this.bars, {required this.color, super.key});

  final List<MarketBar> bars;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SparklinePainter(bars, color));
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.bars, this.color);

  final List<MarketBar> bars;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final prices = bars
        .map((bar) => double.parse(bar.close))
        .toList(growable: false);
    final low = prices.reduce(math.min);
    final span = math.max(prices.reduce(math.max) - low, 0.01);
    final path = Path();
    for (final (index, price) in prices.indexed) {
      final x = index * size.width / (prices.length - 1);
      final y = 2 + (1 - (price - low) / span) * (size.height - 4);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.23),
            color.withValues(alpha: 0.03),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(path, _stroke(color, 1.3));
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.color != color;
}

Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..strokeWidth = width
  ..style = PaintingStyle.stroke;

void _label(
  Canvas canvas,
  String text,
  Offset origin, {
  double align = 0,
  double fontSize = 11,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: numericStyle.copyWith(color: terminalMuted, fontSize: fontSize),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, origin.translate(-painter.width * align, 0));
  painter.dispose();
}
