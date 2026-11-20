import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'terminal_theme.dart';

const _channel = MethodChannel('mikustock/window');

void windowAction(String action) {
  _channel.invokeMethod<void>(action).ignore();
}

class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons>
    with WidgetsBindingObserver {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readSize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _readSize();

  Future<void> _readSize() async {
    try {
      final value = await _channel.invokeMethod<bool>('isMaximized') ?? false;
      if (mounted && value != _maximized) setState(() => _maximized = value);
    } on MissingPluginException {
      // Other platforms can supply a native title bar.
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _button('最小化', Icons.remove, 'minimize'),
      _button(
        _maximized ? '还原' : '最大化',
        _maximized ? Icons.filter_none : Icons.crop_square,
        'toggleMaximize',
      ),
      _button('关闭', Icons.close, 'close', close: true),
    ],
  );

  Widget _button(
    String label,
    IconData icon,
    String action, {
    bool close = false,
  }) => Tooltip(
    message: label,
    child: TextButton(
      onPressed: () => windowAction(action),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 50)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        foregroundColor: const WidgetStatePropertyAll(terminalText),
        overlayColor: WidgetStatePropertyAll(
          close ? const Color(0xffaa2734) : terminalSurface,
        ),
      ),
      child: Icon(icon, size: 17, semanticLabel: label),
    ),
  );
}
