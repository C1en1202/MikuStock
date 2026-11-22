import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

class ModuleTransition extends StatelessWidget {
  const ModuleTransition({
    required this.module,
    required this.child,
    super.key,
  });

  final Object module;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: ValueKey(module), child: child);
    if (MediaQuery.disableAnimationsOf(context)) return content;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: _transition,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, ?currentChild],
        ),
        child: content,
      ),
    );
  }

  // Overlap both pages so there is no pause or hard replacement at peak blur.
  static Widget _transition(Widget child, Animation<double> animation) =>
      AnimatedBuilder(
        animation: animation,
        child: RepaintBoundary(child: child),
        builder: (context, child) {
          final progress = animation.value;
          final blur = (1 - Curves.easeOutCubic.transform(progress)) * 8;
          final opacity = Curves.easeInOutCubic.transform(progress);
          final leaving =
              animation.status == AnimationStatus.reverse ||
              animation.status == AnimationStatus.dismissed;
          return IgnorePointer(
            ignoring: leaving,
            child: ExcludeFocus(
              excluding: leaving,
              child: ExcludeSemantics(
                excluding: leaving,
                child: Opacity(
                  opacity: opacity,
                  child: ImageFiltered(
                    enabled: blur > 0,
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: blur,
                      sigmaY: blur,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
      );
}
