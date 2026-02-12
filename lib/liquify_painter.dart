import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class LiquifyPainter extends CustomPainter {
  final ui.Image image;
  final List<LiquifyStroke> strokes;
  final double brushSize;
  final double brushIntensity;
  final Offset? currentPosition;

  LiquifyPainter({
    required this.image,
    required this.strokes,
    this.brushSize = 50.0,
    this.brushIntensity = 0.5,
    this.currentPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the original image
    final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());

    // Draw brush preview at current position
    if (currentPosition != null) {
      final paint = Paint()
        ..color = Colors.white.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      
      canvas.drawCircle(currentPosition!, brushSize / 2, paint);
      
      final innerPaint = Paint()
        ..color = Colors.white.withOpacity(0.1)
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(currentPosition!, brushSize / 2, innerPaint);
    }
  }

  @override
  bool shouldRepaint(LiquifyPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.strokes.length != strokes.length ||
        oldDelegate.brushSize != brushSize ||
        oldDelegate.currentPosition != currentPosition;
  }
}

class LiquifyStroke {
  final Offset start;
  final Offset end;
  final double brushSize;
  final double intensity;
  final DateTime timestamp;

  LiquifyStroke({
    required this.start,
    required this.end,
    required this.brushSize,
    required this.intensity,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
