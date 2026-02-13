import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';

/// Manages a displacement map for liquify effects using GPU acceleration
class DisplacementMap {
  ui.Image? _displacementTexture;
  final int width;
  final int height;
  Float32List _displacementData; // RGBA format: R=dx, G=dy, B=radius, A=intensity
  
  DisplacementMap(this.width, this.height)
      : _displacementData = Float32List(width * height * 4);

  /// Add a displacement stroke to the map
  void addDisplacement(
    Offset start,
    Offset end,
    double brushRadius,
    double intensity,
  ) {
    final dx = (end.dx - start.dx) * intensity;
    final dy = (end.dy - start.dy) * intensity;
    final distance = math.sqrt(dx * dx + dy * dy);
    
    if (distance < 0.1) return;
    
    final dirX = dx / distance;
    final dirY = dy / distance;
    
    // Calculate affected region
    final minX = (math.min(start.dx, end.dx) - brushRadius).floor().clamp(0, width - 1);
    final maxX = (math.max(start.dx, end.dx) + brushRadius).ceil().clamp(0, width - 1);
    final minY = (math.min(start.dy, end.dy) - brushRadius).floor().clamp(0, height - 1);
    final maxY = (math.max(start.dy, end.dy) + brushRadius).ceil().clamp(0, height - 1);
    
    // Apply Gaussian-weighted displacement
    for (int y = minY; y <= maxY; y++) {
      for (int x = minX; x <= maxX; x++) {
        final pixelX = x.toDouble();
        final pixelY = y.toDouble();
        
        // Calculate distance from stroke line
        final toStartX = pixelX - start.dx;
        final toStartY = pixelY - start.dy;
        final t = math.max(0.0, math.min(1.0, (toStartX * dirX + toStartY * dirY) / distance));
        final projX = start.dx + t * dx;
        final projY = start.dy + t * dy;
        
        final distToLine = math.sqrt(
          math.pow(pixelX - projX, 2) + math.pow(pixelY - projY, 2),
        );
        
        if (distToLine < brushRadius) {
          final falloff = 1.0 - (distToLine / brushRadius);
          final strength = falloff * falloff * intensity;
          
          final idx = (y * width + x) * 4;
          
          // Accumulate displacement (additive)
          _displacementData[idx] += dirX * strength * brushRadius * 0.8; // R = dx
          _displacementData[idx + 1] += dirY * strength * brushRadius * 0.8; // G = dy
          _displacementData[idx + 2] = math.max(_displacementData[idx + 2], brushRadius); // B = max radius
          _displacementData[idx + 3] = math.max(_displacementData[idx + 3], strength); // A = max intensity
        }
      }
    }
  }
  
  /// Build the displacement texture from current data
  Future<ui.Image> buildTexture() async {
    // Normalize displacement data to 0-1 range for texture
    final normalizedData = Uint8List(width * height * 4);
    final maxDisplacement = 50.0; // Max pixel displacement
    
    for (int i = 0; i < _displacementData.length; i += 4) {
      // Normalize dx, dy to 0-1 range (0.5 = no displacement)
      normalizedData[i] = ((_displacementData[i] / maxDisplacement) * 127.5 + 127.5).clamp(0, 255).round();
      normalizedData[i + 1] = ((_displacementData[i + 1] / maxDisplacement) * 127.5 + 127.5).clamp(0, 255).round();
      normalizedData[i + 2] = (_displacementData[i + 2] / 200.0 * 255).clamp(0, 255).round();
      normalizedData[i + 3] = (_displacementData[i + 3] * 255).clamp(0, 255).round();
    }
    
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      normalizedData,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image image) => completer.complete(image),
    );
    
    return completer.future;
  }
  
  /// Reset the displacement map
  void reset() {
    _displacementData = Float32List(width * height * 4);
    _displacementTexture = null;
  }
  
  ui.Image? get texture => _displacementTexture;
}
