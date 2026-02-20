import 'package:flutter/material.dart';

class BadgeWidget extends StatelessWidget {
  final Widget child;
  final int count;
  final double top;
  final double right;

  const BadgeWidget({
    super.key,
    required this.child,
    required this.count,
    this.top = -4,
    this.right = -4,
  });

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (count > 0)
          Positioned(
            top: top,
            right: right,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
