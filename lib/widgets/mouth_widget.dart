import 'package:flutter/material.dart';

class MouthWidget extends StatelessWidget {
  final double openAmount; // 0.0 = closed, 1.0 = fully open
  final double baseWidth;
  final double height;
  final double extraWidth;
  final double radius;
  final Color color;

  const MouthWidget({
    super.key,
    required this.openAmount,
    this.baseWidth = 300,
    this.height = 30,
    this.extraWidth = 12,
    this.radius = 28,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final currentWidth = baseWidth + (extraWidth * openAmount);
    final currentHeight = height * (0.3 + 0.7 * openAmount);
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 50),
      width: currentWidth,
      height: currentHeight,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

