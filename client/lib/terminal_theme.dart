import 'package:material_ui/material_ui.dart';

const terminalBackground = Color(0xff0d141e);
const terminalPanel = Color(0xff141e2b);
const terminalHeader = Color(0xff111a27);
const terminalSurface = Color(0xff1a2636);
const terminalBorder = Color(0xff233144);
const terminalText = Color(0xffedf2f9);
const terminalMuted = Color(0xff97a8bd);
const terminalBlue = Color(0xff4b99ff);
const terminalRed = Color(0xffff626d);
const terminalGreen = Color(0xff4ad4a1);
const terminalGold = Color(0xffffc46e);
const numericStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

Color changeColor(double? value) {
  if (value == null || value == 0) return terminalText;
  return value > 0 ? terminalRed : terminalGreen;
}

String signed(double value) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}';

String compactNumber(num value) {
  if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(2)}亿';
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(2)}万';
  return value.toStringAsFixed(0);
}
