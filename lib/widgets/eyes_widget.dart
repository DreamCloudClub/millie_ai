import 'package:flutter/material.dart';

class EyesWidget extends StatelessWidget {
  const EyesWidget({super.key});

  @override
  Widget build(BuildContext context) {
    // fixed pixel sizes for now
    const double eyeWidth = 250;
    const double eyeHeight = 350;
    const double eyeGap = 50;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // left eye
        Container(
          width: eyeWidth,
          height: eyeHeight,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        const SizedBox(width: eyeGap),
        // right eye
        Container(
          width: eyeWidth,
          height: eyeHeight,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ],
    );
  }
}

