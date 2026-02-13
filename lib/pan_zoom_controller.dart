import 'package:flutter/material.dart';

class PanZoomController {
  double zoomScale = 1.0;
  Offset panOffset = Offset.zero;
  Offset? lastFocalPoint;
  
  // Zoom damping factor for smoother control (lower = slower zoom)
  static const double zoomDampingFactor = 0.03;
  
  // Zoom limits
  static const double minZoom = 0.5;
  static const double maxZoom = 5.0;
  
  void handleScaleStart(ScaleStartDetails details, {required int pointerCount}) {
    if (pointerCount == 2) {
      lastFocalPoint = details.localFocalPoint;
    }
  }
  
  void handleScaleUpdate(
    ScaleUpdateDetails details, {
    required int pointerCount,
    required Size screenSize,
    required double gestureAreaHeight,
  }) {
    if (pointerCount == 2) {
      // Always allow panning with two fingers
      final delta = details.focalPointDelta;
      panOffset = Offset(
        panOffset.dx + delta.dx,
        panOffset.dy + delta.dy,
      );

      // Handle zoom (pinch) with damping
      const double epsilon = 0.005; // Ignore tiny scale noise
      final scaleDelta = details.scale - 1.0;

      if (scaleDelta.abs() > epsilon) {
        final dampedScale = 1.0 + (scaleDelta * zoomDampingFactor);
        final newZoom = (zoomScale * dampedScale).clamp(minZoom, maxZoom);

        // Zoom around focal point
        if (lastFocalPoint != null) {
          final zoomDelta = newZoom - zoomScale;

          // Adjust pan offset to zoom around focal point
          final centerX = screenSize.width / 2;
          final centerY = gestureAreaHeight / 2;

          // Calculate focal point relative to image center
          final focalRelativeToCenter = details.localFocalPoint - Offset(centerX, centerY);

          // Adjust pan offset based on zoom
          panOffset = Offset(
            panOffset.dx - focalRelativeToCenter.dx * (zoomDelta / zoomScale),
            panOffset.dy - focalRelativeToCenter.dy * (zoomDelta / zoomScale),
          );
        }

        zoomScale = newZoom;
        lastFocalPoint = details.localFocalPoint;
      }
    }
    // Single finger drag in frame mode = pan
    else if (pointerCount == 1) {
      final delta = details.focalPointDelta;
      panOffset = Offset(
        panOffset.dx + delta.dx,
        panOffset.dy + delta.dy,
      );
    }
  }
  
  void handleScaleEnd() {
    lastFocalPoint = null;
  }
  
  void reset() {
    zoomScale = 1.0;
    panOffset = Offset.zero;
    lastFocalPoint = null;
  }
}
