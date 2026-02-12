import 'dart:ui';

import 'package:image/image.dart';

class Data {
  final Image imageData;
  final Offset start;
  final Offset end;
  final double brushSize;
  final double intensity;

  Data({required this.imageData, required this.start, required this.end, required this.brushSize, required this.intensity});
}