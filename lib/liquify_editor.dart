import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'liquify_painter.dart';

class LiquifyEditor extends StatefulWidget {
  final Uint8List imageBytes;

  const LiquifyEditor({super.key, required this.imageBytes});

  @override
  State<LiquifyEditor> createState() => _LiquifyEditorState();
}

class _LiquifyEditorState extends State<LiquifyEditor> {
  ui.Image? _originalImage;
  ui.Image? _currentImage;
  img.Image? _workingImage; // Keep in img.Image format for faster warping
  final List<LiquifyStroke> _strokes = [];
  Offset? _currentPosition;
  double _brushSize = 50.0;
  double _brushIntensity = 0.5;
  double _baseScale = 1.0; // Base scale to fit image to screen
  double _zoomScale = 1.0; // User zoom level (pinch)
  Offset _panOffset = Offset.zero; // Pan offset for zoomed image
  Offset? _lastFocalPoint; // Last focal point for pinch gesture
  Size? _gestureAreaSize; // Size of the gesture detector area
  
  // Mode selection: 'frame' for zoom/pan, 'liquify' for editing
  String _currentMode = 'liquify'; // 'frame' or 'liquify'

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  // Step 1: Load Image into Image object
  Future<void> _loadImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    
    // Convert to img.Image format for warping operations
    final imgData = await _uiImageToImage(frame.image);
    
    setState(() {
      _originalImage = frame.image;
      _currentImage = frame.image;
      _workingImage = imgData;
    });
  }

  Offset _displayToImageCoordinates(Offset localPos) {
    if (_gestureAreaSize == null || _currentImage == null) {
      return Offset.zero;
    }
    
    final imageSize = Size(_currentImage!.width.toDouble(), _currentImage!.height.toDouble());
    final baseDisplaySize = Size(imageSize.width * _baseScale, imageSize.height * _baseScale);

    // GestureDetector localPos is relative to the GestureDetector widget (0,0 at top-left)
    // CustomPaint is centered within the GestureDetector using Center widget
    final centerX = _gestureAreaSize!.width / 2;
    final centerY = _gestureAreaSize!.height / 2;
    
    // Account for pan offset and find where CustomPaint center is in GestureDetector coordinates
    final paintCenterX = centerX + _panOffset.dx;
    final paintCenterY = centerY + _panOffset.dy;
    
    // Convert GestureDetector local position to CustomPaint local coordinates
    // The CustomPaint is scaled by _zoomScale, so we need to undo that
    final localX = (localPos.dx - paintCenterX) / _zoomScale;
    final localY = (localPos.dy - paintCenterY) / _zoomScale;
    
    // Convert from center-relative to top-left-relative coordinates
    final paintX = localX + baseDisplaySize.width / 2;
    final paintY = localY + baseDisplaySize.height / 2;

    // Convert CustomPaint coordinates to image coordinates
    final imageX = paintX / _baseScale;
    final imageY = paintY / _baseScale;

    return Offset(imageX, imageY);
  }


  // Step 3: Calculate Deformation based on brush size and distance from touch point
  void _applyDeformation(Offset start, Offset end) {
    if (_currentImage == null || _workingImage == null) return;

    // Calculate warp factor based on brush size and distance
    final strokeDistance = (end - start).distance;
    if (strokeDistance < 1.0) return;

    // Apply warp to working image
    final warpedImage = _calculateWarp(
      _workingImage!,
      start,
      end,
      _brushSize,
      _brushIntensity,
    );

    // Update working image
    _workingImage = warpedImage;

    // Step 4: Redraw Canvas - Convert back to UI Image and trigger repaint
    _updateCanvasImage(warpedImage);
  }

  // Calculate warp deformation
  img.Image _calculateWarp(
    img.Image image,
    Offset start,
    Offset end,
    double brushSize,
    double intensity,
  ) {
    final width = image.width;
    final height = image.height;
    final output = img.Image.from(image);

    // Calculate displacement vector
    final dx = (end.dx - start.dx) * intensity;
    final dy = (end.dy - start.dy) * intensity;
    final distance = math.sqrt(dx * dx + dy * dy);

    if (distance < 0.1) return output;

    // Normalize direction
    final dirX = dx / distance;
    final dirY = dy / distance;
    final brushRadius = brushSize / 2;

    // Calculate affected region bounds
    final minX = (math.min(start.dx, end.dx) - brushRadius).floor().clamp(0, width - 1);
    final maxX = (math.max(start.dx, end.dx) + brushRadius).ceil().clamp(0, width - 1);
    final minY = (math.min(start.dy, end.dy) - brushRadius).floor().clamp(0, height - 1);
    final maxY = (math.max(start.dy, end.dy) + brushRadius).ceil().clamp(0, height - 1);

    // Apply warp only to affected region
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
          // Calculate falloff based on distance from touch point
          final falloff = 1.0 - (distToLine / brushRadius);
          final strength = falloff * falloff * intensity;

          // Calculate displacement
          final displacementX = dirX * strength * brushRadius * 0.8;
          final displacementY = dirY * strength * brushRadius * 0.8;

          // Backward mapping
          final srcX = (pixelX - displacementX).round().clamp(0, width - 1);
          final srcY = (pixelY - displacementY).round().clamp(0, height - 1);

          final pixel = image.getPixel(srcX, srcY);
          output.setPixel(x, y, pixel);
        }
      }
    }

    return output;
  }

  // Update canvas image and trigger repaint
  Future<void> _updateCanvasImage(img.Image warpedImage) async {
    final uiImage = await _imageToUiImage(warpedImage);
    
    if (mounted) {
      setState(() {
        _currentImage = uiImage;
      });
    }
  }

  Future<img.Image> _uiImageToImage(ui.Image uiImage) async {
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();
    return img.decodeImage(bytes)!;
  }

  Future<ui.Image> _imageToUiImage(img.Image image) async {
    final pngBytes = Uint8List.fromList(img.encodePng(image));
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _resetImage() {
    if (_originalImage == null) return;
    
    _uiImageToImage(_originalImage!).then((imgData) {
      setState(() {
        _currentImage = _originalImage;
        _workingImage = imgData;
        _strokes.clear();
        _currentPosition = null;
        _zoomScale = 1.0;
        _panOffset = Offset.zero;
      });
    });
  }

  void _handleScaleStart(ScaleStartDetails details) {
    if (_currentMode == 'frame') {
      // Frame mode: handle zoom/pan
      if (details.pointerCount == 2) {
        _lastFocalPoint = details.localFocalPoint;
      }
    } else {
      // Liquify mode: handle liquify
      if (details.pointerCount == 1) {
        final imagePos = _displayToImageCoordinates(details.localFocalPoint);
        setState(() {
          _currentPosition = imagePos;
        });
      }
    }
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_currentImage == null) return;

    if (_currentMode == 'frame') {
      // FRAME MODE: Zoom and Pan only
      if (details.pointerCount == 2) {
        // Handle zoom (pinch)
        if (details.scale != 1.0) {
          // Reduce zoom sensitivity by using a damped scale factor
          final scaleDelta = details.scale - 1.0;
          final dampedScale = 1.0 + (scaleDelta * 0.08); // Reduce sensitivity to 8% for much smoother control
          final newZoom = (_zoomScale * dampedScale).clamp(0.5, 5.0);
          
          // Zoom around focal point
          if (_lastFocalPoint != null) {
            final zoomDelta = newZoom - _zoomScale;
            
            // Adjust pan offset to zoom around focal point
            final screenSize = MediaQuery.of(context).size;
            final gestureAreaHeight = screenSize.height - 200;
            final centerX = screenSize.width / 2;
            final centerY = gestureAreaHeight / 2;
            
            // Calculate focal point relative to image center
            final focalRelativeToCenter = details.focalPoint - Offset(centerX, centerY);
            
            // Adjust pan offset based on zoom
            _panOffset = Offset(
              _panOffset.dx - focalRelativeToCenter.dx * (zoomDelta / _zoomScale),
              _panOffset.dy - focalRelativeToCenter.dy * (zoomDelta / _zoomScale),
            );
          }
          
          setState(() {
            _zoomScale = newZoom;
            _lastFocalPoint = details.focalPoint;
          });
        }
        // Handle pan (two fingers moving without scaling)
        else if (details.scale == 1.0) {
          final delta = details.focalPointDelta;
          setState(() {
            _panOffset = Offset(
              _panOffset.dx + delta.dx,
              _panOffset.dy + delta.dy,
            );
          });
        }
      }
      // Single finger drag in frame mode = pan
      else if (details.pointerCount == 1) {
        final delta = details.focalPointDelta;
        setState(() {
          _panOffset = Offset(
            _panOffset.dx + delta.dx,
            _panOffset.dy + delta.dy,
          );
        });
      }
    } else {
      // LIQUIFY MODE: Apply liquify effect only
      if (details.pointerCount == 1) {
        final newImagePosition = _displayToImageCoordinates(details.localFocalPoint);

        if (_currentPosition != null) {
          // Step 3 & 4: Calculate deformation and update canvas
          _applyDeformation(_currentPosition!, newImagePosition);
          
          // Add stroke to history
          _strokes.add(LiquifyStroke(
            start: _currentPosition!,
            end: newImagePosition,
            brushSize: _brushSize,
            intensity: _brushIntensity,
          ));
        }

        setState(() {
          _currentPosition = newImagePosition;
        });
      }
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _lastFocalPoint = null;
    setState(() {
      _currentPosition = null;
    });
  }

  Future<Uint8List?> _saveImage() async {
    if (_currentImage == null) return null;
    final byteData = await _currentImage!.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentImage == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final imageSize = Size(_currentImage!.width.toDouble(), _currentImage!.height.toDouble());
    final screenSize = MediaQuery.of(context).size;
    _baseScale = math.min(
      screenSize.width / imageSize.width,
      (screenSize.height - 200) / imageSize.height,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Liquify Editor'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: _resetImage,
            tooltip: 'Reset',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () async {
              final savedBytes = await _saveImage();
              if (savedBytes != null && mounted) {
                Navigator.of(context).pop(savedBytes);
              }
            },
            tooltip: 'Save',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Store the gesture area size for coordinate conversion
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_gestureAreaSize != constraints.biggest) {
                    setState(() {
                      _gestureAreaSize = constraints.biggest;
                    });
                  }
                });
                
                return GestureDetector(
                  // Combined gesture handler: handles both zoom (pinch) and liquify (drag)
                  onScaleStart: _handleScaleStart,
                  onScaleUpdate: _handleScaleUpdate,
                  onScaleEnd: _handleScaleEnd,
                  child: Transform.translate(
                offset: _panOffset,
                child: Center(
                  // Step 4: CustomPainter redraws canvas with updated image
                  child: Transform.scale(
                    scale: _zoomScale,
                    child: CustomPaint(
                      size: Size(
                        imageSize.width * _baseScale,
                        imageSize.height * _baseScale,
                      ),
                      painter: LiquifyPainter(
                        image: _currentImage!,
                        strokes: _strokes,
                        brushSize: _brushSize * _baseScale,
                        brushIntensity: _brushIntensity,
                        currentPosition: _currentPosition != null
                            ? Offset(
                                _currentPosition!.dx * _baseScale,
                                _currentPosition!.dy * _baseScale,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
                );
              },
            ),
          ),
          // Mode selection buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Mode toggle buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Frame/Adjust Mode Button
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _currentMode = 'frame';
                            _currentPosition = null;
                          });
                        },
                        icon: Icon(
                          _currentMode == 'frame' ? Icons.crop_free : Icons.crop_free_outlined,
                        ),
                        label: const Text('Frame'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _currentMode == 'frame'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.surface,
                          foregroundColor: _currentMode == 'frame'
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurface,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Liquify Mode Button
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _currentMode = 'liquify';
                          });
                        },
                        icon: Icon(
                          _currentMode == 'liquify' ? Icons.brush : Icons.brush_outlined,
                        ),
                        label: const Text('Liquify'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _currentMode == 'liquify'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.surface,
                          foregroundColor: _currentMode == 'liquify'
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurface,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                // Liquify controls (only show in liquify mode)
                if (_currentMode == 'liquify') ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.brush, size: 20),
                      const SizedBox(width: 8),
                      const Text('Brush Size:'),
                      Expanded(
                        child: Slider(
                          value: _brushSize,
                          min: 10,
                          max: 200,
                          divisions: 19,
                          label: _brushSize.round().toString(),
                          onChanged: (value) {
                            setState(() {
                              _brushSize = value;
                            });
                          },
                        ),
                      ),
                      Text('${_brushSize.round()}'),
                    ],
                  ),
                  Row(
                    children: [
                      const Icon(Icons.tune, size: 20),
                      const SizedBox(width: 8),
                      const Text('Intensity:'),
                      Expanded(
                        child: Slider(
                          value: _brushIntensity,
                          min: 0.1,
                          max: 1.0,
                          divisions: 9,
                          label: _brushIntensity.toStringAsFixed(1),
                          onChanged: (value) {
                            setState(() {
                              _brushIntensity = value;
                            });
                          },
                        ),
                      ),
                      Text(_brushIntensity.toStringAsFixed(1)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
