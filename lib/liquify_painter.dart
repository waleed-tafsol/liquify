import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class LiquifyPainter extends CustomPainter {
  final ui.Image image;
  final List<LiquifyStroke> strokes;
  final double brushSize;
  final double brushIntensity;
  final Offset? currentPosition;
  final Offset? currentDisplacement; // Current stroke displacement vector
  final Offset? previousPosition; // Previous position for calculating displacement
  static ui.FragmentProgram? _shaderProgram;
  static bool _shaderInitialized = false;

  LiquifyPainter({
    required this.image,
    required this.strokes,
    this.brushSize = 50.0,
    this.brushIntensity = 0.5,
    this.currentPosition,
    this.currentDisplacement,
    this.previousPosition,
  });

  static Future<void> initializeShader() async {
    if (_shaderInitialized) return;
    // Temporarily disable shader to avoid build issues
    // Shader functionality will be re-enabled once build issues are resolved
    _shaderInitialized = true;
    return;
    
    // Original shader initialization code (commented out)
    /*
    try {
      _shaderProgram = await ui.FragmentProgram.fromAsset('shaders/liquify.frag');
      _shaderInitialized = true;
    } catch (e) {
      debugPrint('Shader initialization failed (falling back to CPU rendering): $e');
      _shaderInitialized = true;
    }
    */
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Performance: Use drawImageRect for efficient image rendering
    // This is much faster than rendering pixels individually
    final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    
    // Use shader for real-time displacement if available and active
    if (_shaderProgram != null && currentPosition != null && currentDisplacement != null) {
      try {
        final shader = _shaderProgram!.fragmentShader();
        
        // Set shader uniforms
        // Note: In Flutter, float uniforms and sampler uniforms use separate indices
        // Float uniforms: uSize (0,1), uDisplacement (2,3), uDisplacementPos (4,5), uBrushRadius (6), uBrushIntensity (7)
        // Sampler uniforms: uTexture (0)
        
        shader.setFloat(0, size.width);   // uSize.x
        shader.setFloat(1, size.height);  // uSize.y
        
        final displacement = currentDisplacement!;
        shader.setFloat(2, displacement.dx);  // uDisplacement.x
        shader.setFloat(3, displacement.dy); // uDisplacement.y
        
        shader.setFloat(4, currentPosition!.dx); // uDisplacementPos.x
        shader.setFloat(5, currentPosition!.dy); // uDisplacementPos.y
        
        shader.setFloat(6, brushSize);         // uBrushRadius
        shader.setFloat(7, brushIntensity);    // uBrushIntensity
        
        shader.setImageSampler(0, image);       // uTexture
        
        // Create paint with shader
        final paint = Paint()
          ..shader = shader
          ..filterQuality = FilterQuality.high;
        
        canvas.drawImageRect(image, srcRect, dstRect, paint);
      } catch (e) {
        // Fall back to regular rendering if shader fails
        debugPrint('Shader rendering failed: $e');
        canvas.drawImageRect(image, srcRect, dstRect, Paint());
      }
    } else {
      // Regular rendering when no active displacement
      canvas.drawImageRect(image, srcRect, dstRect, Paint());
    }

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
    // Repaint if image, brush position, displacement, or brush size changed
    return oldDelegate.image != image ||
        oldDelegate.brushSize != brushSize ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.currentDisplacement != currentDisplacement ||
        oldDelegate.previousPosition != previousPosition;
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
