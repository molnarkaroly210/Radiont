import 'package:flutter/material.dart';

class PressableScaleWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const PressableScaleWidget({super.key, required this.child, this.onTap});

  @override
  State<PressableScaleWidget> createState() => _PressableScaleWidgetState();
}

class _PressableScaleWidgetState extends State<PressableScaleWidget> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onTap?.call();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.85 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
