import 'package:flutter/material.dart';
import '../utils/constants.dart';

/// A cartoon-style thought bubble with cloud edges and trailing dots
class ThoughtBubble extends StatelessWidget {
  final Widget child;
  final Color backgroundColor;
  final Color borderColor;
  final double borderWidth;

  const ThoughtBubble({
    super.key,
    required this.child,
    this.backgroundColor = const Color(0xFF2A2A2A),
    this.borderColor = const Color(0xFF4A9EFF),
    this.borderWidth = 2.5,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Main bubble
        CustomPaint(
          painter: _ThoughtBubblePainter(
            backgroundColor: backgroundColor,
            borderColor: borderColor,
            borderWidth: borderWidth,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 28,
              vertical: 20,
            ),
            child: child,
          ),
        ),
        // Trailing dots
        _buildTrailingDots(),
      ],
    );
  }

  Widget _buildTrailingDots() {
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          // First dot (largest, closest to bubble)
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: backgroundColor,
              shape: BoxShape.circle,
              border: Border.all(color: borderColor, width: borderWidth),
              boxShadow: [
                BoxShadow(
                  color: borderColor.withOpacity(0.2),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8, height: 12),
          // Second dot (medium)
          Transform.translate(
            offset: const Offset(0, 10),
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: backgroundColor,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: borderWidth),
                boxShadow: [
                  BoxShadow(
                    color: borderColor.withOpacity(0.2),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Third dot (smallest, furthest)
          Transform.translate(
            offset: const Offset(0, 20),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: backgroundColor,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: borderWidth),
                boxShadow: [
                  BoxShadow(
                    color: borderColor.withOpacity(0.2),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for the cloud-like thought bubble shape
class _ThoughtBubblePainter extends CustomPainter {
  final Color backgroundColor;
  final Color borderColor;
  final double borderWidth;

  _ThoughtBubblePainter({
    required this.backgroundColor,
    required this.borderColor,
    required this.borderWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    final shadowPaint = Paint()
      ..color = borderColor.withOpacity(0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

    final path = _createCloudPath(size);

    // Draw shadow
    canvas.drawPath(path.shift(const Offset(0, 4)), shadowPaint);
    
    // Draw fill
    canvas.drawPath(path, paint);
    
    // Draw border
    canvas.drawPath(path, borderPaint);
  }

  Path _createCloudPath(Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;
    
    // Cloud bump parameters
    final bumpRadius = h * 0.18;  // Size of the bumps
    
    // Start from bottom-left
    path.moveTo(bumpRadius, h);
    
    // Bottom edge - gentle bumps
    final bottomBumps = 4;
    final bottomStep = (w - bumpRadius * 2) / bottomBumps;
    for (int i = 0; i < bottomBumps; i++) {
      final x1 = bumpRadius + bottomStep * i + bottomStep * 0.5;
      final x2 = bumpRadius + bottomStep * (i + 1);
      path.quadraticBezierTo(x1, h + bumpRadius * 0.3, x2, h);
    }
    
    // Right edge - larger bumps going up
    final rightBumps = 3;
    final rightStep = (h - bumpRadius * 2) / rightBumps;
    for (int i = 0; i < rightBumps; i++) {
      final y1 = h - bumpRadius - rightStep * i - rightStep * 0.5;
      final y2 = h - bumpRadius - rightStep * (i + 1);
      path.quadraticBezierTo(w + bumpRadius * 0.4, y1, w, y2);
    }
    
    // Top edge - bumps going left
    final topBumps = 4;
    final topStep = (w - bumpRadius * 2) / topBumps;
    for (int i = 0; i < topBumps; i++) {
      final x1 = w - bumpRadius - topStep * i - topStep * 0.5;
      final x2 = w - bumpRadius - topStep * (i + 1);
      path.quadraticBezierTo(x1, -bumpRadius * 0.3, x2, 0);
    }
    
    // Left edge - bumps going down
    final leftBumps = 3;
    final leftStep = (h - bumpRadius * 2) / leftBumps;
    for (int i = 0; i < leftBumps; i++) {
      final y1 = bumpRadius + leftStep * i + leftStep * 0.5;
      final y2 = bumpRadius + leftStep * (i + 1);
      path.quadraticBezierTo(-bumpRadius * 0.4, y1, 0, y2);
    }
    
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

