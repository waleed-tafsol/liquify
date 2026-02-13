import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'liquify_painter.dart';
import 'pan_zoom_controller.dart';

class LiquifyEditor extends StatefulWidget {
  final Uint8List imageBytes;

  const LiquifyEditor({super.key, required this.imageBytes});

  @override
  State<LiquifyEditor> createState() => _LiquifyEditorState();
}

/// Editing modes for the liquify editor.
enum EditingMode {
  frame,   // Pan & zoom
  liquify, // Apply liquify brush
}

class _LiquifyEditorState extends State<LiquifyEditor> {
  ui.Image? _originalImage;
  ui.Image? _currentImage;
  img.Image? _workingImage; // Keep in img.Image format for faster warping
  final List<LiquifyStroke> _strokes = [];
  Offset? _currentPosition;
  Offset? _previousPosition; // For calculating displacement vector
  Offset? _currentDisplacement; // Current displacement vector for shader
  double _brushSize = 50.0;
  double _brushIntensity = 0.5;
  double _baseScale = 1.0; // Base scale to fit image to screen
  final PanZoomController _panZoomController = PanZoomController();
  Size? _gestureAreaSize; // Size of the gesture detector area
  bool _isLoadingImage = false; // Loading state for image processing
  bool _isSaving = false; // Loading state for saving image
  
  // Throttling for liquify updates
  Timer? _updateTimer;
  Offset? _pendingStart;
  Offset? _pendingEnd;
  DateTime _lastUpdateTime = DateTime.now();
  static const Duration _updateThrottle = Duration(milliseconds: 16); // Update max every 16ms (~60fps)
  static const int _maxImageDimension = 800; // Max size of the working image (longest side)
  
  // Mode selection
  EditingMode _currentMode = EditingMode.liquify;

  @override
  void initState() {
    super.initState();
    // Initialize shader asynchronously
    LiquifyPainter.initializeShader();
    _loadImage();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  // Step 1: Load Image into Image object
  Future<void> _loadImage() async {
    try {
      if (mounted) {
        setState(() {
          _isLoadingImage = true;
        });
      }

      // Yield to UI thread to show loading indicator immediately
      await Future.delayed(const Duration(milliseconds: 50));

      // Decode image to check dimensions
      final decodedImage = img.decodeImage(widget.imageBytes);
      if (decodedImage == null) {
        if (mounted) {
          setState(() {
            _isLoadingImage = false;
          });
        }
        return;
      }

      // Check if image is too large for smooth editing
      const maxDimension = _maxImageDimension;
      final width = decodedImage.width;
      final height = decodedImage.height;
      
      img.Image imageToProcess = decodedImage;
      bool needsResizing = width > maxDimension || height > maxDimension;
      
      if (needsResizing) {
        // Yield to UI thread during heavy processing
        await Future.delayed(const Duration(milliseconds: 10));
        
        // Calculate new dimensions maintaining aspect ratio
        double scale;
        if (width > height) {
          scale = maxDimension / width;
        } else {
          scale = maxDimension / height;
        }
        
        final newWidth = (width * scale).round();
        final newHeight = (height * scale).round();
        
        // Resize image for smooth editing
        imageToProcess = img.copyResize(
          decodedImage,
          width: newWidth,
          height: newHeight,
          interpolation: img.Interpolation.linear,
        );
        
        // Yield to UI thread
        await Future.delayed(const Duration(milliseconds: 10));
      }

      // Convert resized image to UI Image
      final pngBytes = Uint8List.fromList(img.encodePng(imageToProcess));
      final codec = await ui.instantiateImageCodec(pngBytes);
      final frame = await codec.getNextFrame();
      final imageToUse = frame.image;

      // Use the processed image for warping operations
      final imgData = imageToProcess;

      if (mounted) {
        setState(() {
          _originalImage = imageToUse;
          _currentImage = imageToUse;
          _workingImage = imgData;
          _isLoadingImage = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingImage = false;
        });
      }
    }
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
    final paintCenterX = centerX + _panZoomController.panOffset.dx;
    final paintCenterY = centerY + _panZoomController.panOffset.dy;
    
    // Convert GestureDetector local position to CustomPaint local coordinates
    // The CustomPaint is scaled by zoomScale, so we need to undo that
    final localX = (localPos.dx - paintCenterX) / _panZoomController.zoomScale;
    final localY = (localPos.dy - paintCenterY) / _panZoomController.zoomScale;
    
    // Convert from center-relative to top-left-relative coordinates
    final paintX = localX + baseDisplaySize.width / 2;
    final paintY = localY + baseDisplaySize.height / 2;

    // Convert CustomPaint coordinates to image coordinates
    final imageX = paintX / _baseScale;
    final imageY = paintY / _baseScale;

    return Offset(imageX, imageY);
  }


  // Process pending deformation with throttling
  void _processPendingDeformation() {
    if (_pendingStart == null || _pendingEnd == null) return;
    if (_currentImage == null || _workingImage == null) return;

    final start = _pendingStart!;
    final end = _pendingEnd!;
    _pendingStart = null;
    _pendingEnd = null;
    _lastUpdateTime = DateTime.now();

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

    // Add stroke to history
    _strokes.add(LiquifyStroke(
      start: start,
      end: end,
      brushSize: _brushSize,
      intensity: _brushIntensity,
    ));

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
        _panZoomController.reset();
      });
    });
  }

  void _handleScaleStart(ScaleStartDetails details) {
    if (_currentMode == EditingMode.frame) {
      // Frame mode: handle zoom/pan
      _panZoomController.handleScaleStart(details, pointerCount: details.pointerCount);
    } else {
      // Liquify mode: handle liquify
      if (details.pointerCount == 1) {
        final imagePos = _displayToImageCoordinates(details.localFocalPoint);
        setState(() {
          _currentPosition = imagePos;
          _previousPosition = null;
          _currentDisplacement = null;
        });
      }
    }
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_currentImage == null) return;

    if (_currentMode == EditingMode.frame) {
      // FRAME MODE: Zoom and Pan only
      final screenSize = MediaQuery.of(context).size;
      final gestureAreaHeight = screenSize.height - 200;
      
      _panZoomController.handleScaleUpdate(
        details,
        pointerCount: details.pointerCount,
        screenSize: screenSize,
        gestureAreaHeight: gestureAreaHeight,
      );
      
      setState(() {
        // Trigger rebuild to update pan/zoom
      });
    } else {
      // LIQUIFY MODE: Apply liquify effect only
      if (details.pointerCount == 1) {
        final newImagePosition = _displayToImageCoordinates(details.localFocalPoint);
        
        // Calculate displacement in screen coordinates for shader
        // The shader works in screen/pixel space
        final screenDisplacement = details.focalPointDelta * _brushIntensity;

        // Store previous position before updating
        final previousPosition = _currentPosition;

        // Update brush position and displacement immediately for visual feedback
        setState(() {
          _previousPosition = previousPosition;
          _currentPosition = newImagePosition;
          _currentDisplacement = screenDisplacement;
        });

        if (previousPosition != null) {
          // Always update pending deformation (accumulate strokes)
          _pendingStart = previousPosition;
          _pendingEnd = newImagePosition;
          
          final now = DateTime.now();
          final timeSinceLastUpdate = now.difference(_lastUpdateTime);
          
          // If enough time has passed, process immediately
          if (timeSinceLastUpdate >= _updateThrottle) {
            // Cancel any pending timer
            _updateTimer?.cancel();
            _updateTimer = null;
            // Process immediately
            _processPendingDeformation();
          } else {
            // Schedule update after throttle period (only if timer not already running)
            _updateTimer?.cancel();
            _updateTimer = Timer(_updateThrottle - timeSinceLastUpdate, () {
              _processPendingDeformation();
              _updateTimer = null;
            });
          }
        }
      }
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    if (_currentMode == EditingMode.frame) {
      _panZoomController.handleScaleEnd();
    } else {
      // Process any pending deformation before ending
      _updateTimer?.cancel();
      if (_pendingStart != null && _pendingEnd != null) {
        _processPendingDeformation();
      }
      // Clear displacement and position for shader
      setState(() {
        _currentDisplacement = null;
        _previousPosition = null;
        _currentPosition = null;
      });
    }
  }

  Future<Uint8List?> _saveImage() async {
    if (_currentImage == null) return null;

    if (mounted) {
      setState(() {
        _isSaving = true;
      });
    }

    // Yield to UI thread to show loading indicator
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      final byteData = await _currentImage!.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();

      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }

      return bytes;
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentImage == null || _isLoadingImage) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Liquify Editor'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _isLoadingImage 
                    ? 'Compressing image for smooth editing...' 
                    : 'Loading image...',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
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
            onPressed: _isSaving ? null : () async {
              final savedBytes = await _saveImage();
              if (savedBytes != null && mounted) {
                Navigator.of(context).pop(savedBytes);
              }
            },
            tooltip: 'Save',
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
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
                offset: _panZoomController.panOffset,
                child: Center(
                  // Step 4: CustomPainter redraws canvas with updated image
                  child: Transform.scale(
                    scale: _panZoomController.zoomScale,
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
                        currentPosition: _currentPosition != null && _currentMode == EditingMode.liquify
                            ? Offset(
                                _currentPosition!.dx * _baseScale,
                                _currentPosition!.dy * _baseScale,
                              )
                            : null,
                        currentDisplacement: _currentDisplacement != null && _currentMode == EditingMode.liquify
                            ? _currentDisplacement! * _baseScale
                            : null,
                        previousPosition: _previousPosition != null && _currentMode == EditingMode.liquify
                            ? Offset(
                                _previousPosition!.dx * _baseScale,
                                _previousPosition!.dy * _baseScale,
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
          // Mode selection buttons with professional styling
          Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 20,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Mode toggle buttons with improved styling
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Frame/Adjust Mode Button
                    Expanded(
                      child: _buildModeButton(
                        context,
                        icon: _currentMode == EditingMode.frame 
                            ? Icons.crop_free 
                            : Icons.crop_free_outlined,
                        label: 'Frame',
                        isActive: _currentMode == EditingMode.frame,
                        onPressed: () {
                          setState(() {
                            _currentMode = EditingMode.frame;
                            _currentPosition = null;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Liquify Mode Button
                    Expanded(
                      child: _buildModeButton(
                        context,
                        icon: _currentMode == EditingMode.liquify 
                            ? Icons.brush 
                            : Icons.brush_outlined,
                        label: 'Liquify',
                        isActive: _currentMode == EditingMode.liquify,
                        onPressed: () {
                          setState(() {
                            _currentMode = EditingMode.liquify;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                // Liquify controls (only show in liquify mode)
                if (_currentMode == EditingMode.liquify) ...[
                  const SizedBox(height: 20),
                  _buildControlRow(
                    context,
                    icon: Icons.brush,
                    label: 'Brush Size',
                    value: _brushSize,
                    min: 10,
                    max: 200,
                    divisions: 19,
                    onChanged: (value) {
                      setState(() {
                        _brushSize = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildControlRow(
                    context,
                    icon: Icons.tune,
                    label: 'Intensity',
                    value: _brushIntensity,
                    min: 0.1,
                    max: 1.0,
                    divisions: 9,
                    formatValue: (val) => val.toStringAsFixed(1),
                    onChanged: (value) {
                      setState(() {
                        _brushIntensity = value;
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
          ),
          // Info overlay showing zoom and brush size
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withOpacity(0.2),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.zoom_in,
                        size: 16,
                        color: Colors.white.withOpacity(0.9),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Zoom: ${(_panZoomController.zoomScale * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  if (_currentMode == EditingMode.liquify) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.brush,
                          size: 16,
                          color: Colors.white.withOpacity(0.9),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Brush: ${_brushSize.round()}px',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Loading overlay when saving
          if (_isSaving)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Saving image at full resolution...',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Helper method to build mode toggle buttons
  Widget _buildModeButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            color: isActive
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline.withOpacity(0.2),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: isActive
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Helper method to build control rows with consistent styling
  Widget _buildControlRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    String Function(double)? formatValue,
  }) {
    final displayValue = formatValue != null 
        ? formatValue(value) 
        : value.round().toString();
    
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                activeColor: Theme.of(context).colorScheme.primary,
                inactiveColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            displayValue,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ],
    );
  }
}
