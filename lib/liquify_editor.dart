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
  final List<LiquifyStroke> _strokes = [];
  Offset? _currentPosition;
  double _brushSize = 50.0;
  double _brushIntensity = 0.5;
  bool _isProcessing = false;
  double _scale = 1.0;
  Offset _imageOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    setState(() {
      _originalImage = frame.image;
      _currentImage = frame.image;
    });
  }

  Offset _displayToImageCoordinates(Offset screenPos) {
    // Convert screen coordinates to image coordinates
    // The screenPos is relative to the Stack, we need to account for centering
    final screenSize = MediaQuery.of(context).size;
    final imageSize = Size(_currentImage!.width.toDouble(), _currentImage!.height.toDouble());
    final displaySize = Size(imageSize.width * _scale, imageSize.height * _scale);

    // Calculate actual image position on screen (centered)
    final imageLeft = (screenSize.width - displaySize.width) / 2;
    final imageTop = ((screenSize.height - 200) - displaySize.height) / 2;

    // Convert to image coordinates
    final imageX = (screenPos.dx - imageLeft) / _scale;
    final imageY = (screenPos.dy - imageTop) / _scale;

    return Offset(imageX, imageY);
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() {
      _currentPosition = null;
    });
  }

  Future<void> _applyLiquifyEffect(LiquifyStroke stroke) async {
    if (_currentImage == null) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      // Convert UI Image to Image package format
      final imageData = await _uiImageToImage(_currentImage!);

      // Apply liquify warp (optimized to only process affected area)
      final warpedImage = _applyWarp(
        imageData,
        stroke.start,
        stroke.end,
        stroke.brushSize,
        stroke.intensity,
      );

      // Convert back to UI Image
      final uiImage = await _imageToUiImage(warpedImage);

      setState(() {
        _currentImage = uiImage;
        _strokes.add(stroke);
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error applying effect: $e')),
        );
      }
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

  img.Image _applyWarp(
      img.Image image,
      Offset start,
      Offset end,
      double brushSize,
      double intensity,
      ) {
    final width = image.width;
    final height = image.height;

    // Create output image by copying the current image
    final output = img.Image.from(image);

    // Calculate displacement vector
    final dx = (end.dx - start.dx) * intensity;
    final dy = (end.dy - start.dy) * intensity;
    final distance = math.sqrt(dx * dx + dy * dy);

    if (distance < 0.1) return output;

    // Normalize direction
    final dirX = dx / distance;
    final dirY = dy / distance;

    // Calculate affected region bounds for optimization
    final brushRadius = brushSize / 2;
    final minX = (math.min(start.dx, end.dx) - brushRadius).floor().clamp(0, width - 1);
    final maxX = (math.max(start.dx, end.dx) + brushRadius).ceil().clamp(0, width - 1);
    final minY = (math.min(start.dy, end.dy) - brushRadius).floor().clamp(0, height - 1);
    final maxY = (math.max(start.dy, end.dy) + brushRadius).ceil().clamp(0, height - 1);

    // Apply warp only to affected region
    for (int y = minY; y <= maxY; y++) {
      for (int x = minX; x <= maxX; x++) {
        final pixelX = x.toDouble();
        final pixelY = y.toDouble();

        // Calculate distance from stroke line (perpendicular distance)
        final toStartX = pixelX - start.dx;
        final toStartY = pixelY - start.dy;
        final strokeLength = distance;

        // Project point onto stroke line
        final t = math.max(0.0, math.min(1.0, (toStartX * dirX + toStartY * dirY) / strokeLength));
        final projX = start.dx + t * dx;
        final projY = start.dy + t * dy;

        // Distance from point to stroke line
        final distToLine = math.sqrt(
          math.pow(pixelX - projX, 2) + math.pow(pixelY - projY, 2),
        );

        if (distToLine < brushRadius) {
          // Calculate falloff (stronger at center, weaker at edges)
          final falloff = 1.0 - (distToLine / brushRadius);
          final strength = falloff * falloff * intensity; // Quadratic falloff

          // Calculate displacement (push pixels along stroke direction)
          final displacementX = dirX * strength * brushRadius * 0.8;
          final displacementY = dirY * strength * brushRadius * 0.8;

          // Source coordinates (backward mapping - where to sample from)
          final srcX = (pixelX - displacementX).round();
          final srcY = (pixelY - displacementY).round();

          // Clamp to image bounds
          final clampedX = srcX.clamp(0, width - 1);
          final clampedY = srcY.clamp(0, height - 1);

          // Sample from source and write to output
          final pixel = image.getPixel(clampedX, clampedY);
          output.setPixel(x, y, pixel);
        }
      }
    }

    return output;
  }

  void _resetImage() {
    setState(() {
      _currentImage = _originalImage;
      _strokes.clear();
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
    _scale = math.min(
      screenSize.width / imageSize.width,
      (screenSize.height - 200) / imageSize.height,
    );
    final displaySize = Size(imageSize.width * _scale, imageSize.height * _scale);

    // Calculate offset to center the image
    _imageOffset = Offset(
      (screenSize.width - displaySize.width) / 2,
      ((screenSize.height - 200) - displaySize.height) / 2,
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
          // Image display area
          Expanded(
            child: Stack(
              children: [

                Center(
                  child: CustomPaint(
                    size: displaySize,
                    painter: LiquifyPainter(
                      image: _currentImage!,
                      strokes: _strokes,
                      brushSize: _brushSize * _scale,
                      brushIntensity: _brushIntensity,
                      currentPosition: _currentPosition != null
                          ? Offset(
                        _currentPosition!.dx * _scale + _imageOffset.dx,
                        _currentPosition!.dy * _scale + _imageOffset.dy,
                      )
                          : null,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    onPanStart: (details) {
                      final imagePos = _displayToImageCoordinates(details.localPosition);
                      setState(() {
                        _currentPosition = imagePos;
                      });
                    },
                    onPanUpdate: (details) async {
                      if (_currentImage == null || _isProcessing) return;

                      final newImagePosition = _displayToImageCoordinates(details.localPosition);

                      if (_currentPosition != null) {
                        final stroke = LiquifyStroke(
                          start: _currentPosition!,
                          end: newImagePosition,
                          brushSize: _brushSize,
                          intensity: _brushIntensity,
                        );

                        setState(() {
                          _currentPosition = newImagePosition;
                        });

                        await _applyLiquifyEffect(stroke);
                      } else {
                        setState(() {
                          _currentPosition = newImagePosition;
                        });
                      }
                    },
                    onPanEnd: _onPanEnd,
                    child: Container(color: Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
          // Controls
          Container(
            padding: const EdgeInsets.all(16),
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
                // Brush Size
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
                // Brush Intensity
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
            ),
          ),
        ],
      ),
    );
  }
}
