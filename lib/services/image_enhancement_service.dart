import 'package:universal_io/io.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class ImageEnhancementService {
  
  ImageEnhancementService() {
    // ML Kit Removed for lightweight build
  }
  
  /// Complete image enhancement pipeline
  Future<File> enhanceImage({
    required File inputImage,
    EnhancementOptions options = const EnhancementOptions(),
    void Function(double progress)? onProgress,
  }) async {
    // Step 1: Load and decode image
    onProgress?.call(0.1);
    final bytes = await inputImage.readAsBytes();
    img.Image? original = img.decodeImage(bytes);
    if (original == null) throw Exception('Failed to decode image');
    
    // Step 2: Auto balance colors
    onProgress?.call(0.2);
    img.Image balanced = options.autoBalance 
        ? _autoBalanceColors(original)
        : original;
    
    // Step 3: Adjust brightness/contrast/saturation
    onProgress?.call(0.3);
    img.Image adjusted = _adjustImageProperties(
      balanced,
      brightness: options.brightness,
      contrast: options.contrast,
      saturation: options.saturation,
    );
    
    // Step 4: Face enhancement (Stubbed - ML Kit removed for weight)
    onProgress?.call(0.5);
    img.Image faceEnhanced = adjusted; 
    
    // Step 5: Apply filter
    onProgress?.call(0.7);
    img.Image filtered = options.filter != null
        ? _applyFilter(faceEnhanced, options.filter!)
        : faceEnhanced;
    
    // Step 6: Sharpen for clarity
    onProgress?.call(0.8);
    img.Image sharpened = options.sharpen
        ? _sharpenImage(filtered, options.sharpenAmount)
        : filtered;
    
    // Step 7: Resize
    onProgress?.call(0.9);
    img.Image resized = _resizeToFitContainer(
      sharpened,
      maxWidth: options.maxWidth,
      maxHeight: options.maxHeight,
      maintainAspectRatio: true,
    );
    
    // Save to file
    final outputPath = await _saveImage(resized);
    onProgress?.call(1.0);
    
    return File(outputPath);
  }
  
  img.Image _autoBalanceColors(img.Image image) {
    final balanced = img.Image.from(image);
    int totalR = 0, totalG = 0, totalB = 0;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        totalR += pixel.r.toInt();
        totalG += pixel.g.toInt();
        totalB += pixel.b.toInt();
      }
    }
    final count = image.width * image.height;
    if (count == 0) return balanced;
    final avgR = totalR / count;
    final avgG = totalG / count;
    final avgB = totalB / count;
    
    final rGain = avgR > 0 ? 128.0 / avgR : 1.0;
    final gGain = avgG > 0 ? 128.0 / avgG : 1.0;
    final bGain = avgB > 0 ? 128.0 / avgB : 1.0;
    
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final r = (pixel.r * rGain).clamp(0, 255).toInt();
        final g = (pixel.g * gGain).clamp(0, 255).toInt();
        final b = (pixel.b * bGain).clamp(0, 255).toInt();
        balanced.setPixelRgba(x, y, r, g, b, pixel.a.toInt());
      }
    }
    return balanced;
  }
  
  img.Image _adjustImageProperties(img.Image image, {double brightness = 0.0, double contrast = 1.0, double saturation = 1.0}) {
    img.Image result = img.Image.from(image);
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        var pixel = image.getPixel(x, y);
        double r = pixel.r + (brightness * 255);
        double g = pixel.g + (brightness * 255);
        double b = pixel.b + (brightness * 255);
        r = ((r - 128) * contrast + 128).clamp(0, 255);
        g = ((g - 128) * contrast + 128).clamp(0, 255);
        b = ((b - 128) * contrast + 128).clamp(0, 255);
        final gray = (r + g + b) / 3;
        r = gray + (r - gray) * saturation;
        g = gray + (g - gray) * saturation;
        b = gray + (b - gray) * saturation;
        result.setPixelRgba(x, y, r.toInt().clamp(0, 255), g.toInt().clamp(0, 255), b.toInt().clamp(0, 255), pixel.a.toInt());
      }
    }
    return result;
  }
  
  img.Image _applyFilter(img.Image image, ImageFilter filter) {
    switch (filter) {
      case ImageFilter.warm:
        return _applyWarmFilter(image);
      case ImageFilter.cool:
        return _applyCoolFilter(image);
      case ImageFilter.vintage:
        return _applyVintageFilter(image);
      case ImageFilter.blackAndWhite:
        return _applyBlackAndWhiteFilter(image);
      default: return image;
    }
  }

  img.Image _applyWarmFilter(img.Image image) {
    final result = img.Image.from(image);
    for (var p in result) {
       p.r = (p.r * 1.2).clamp(0, 255);
       p.g = (p.g * 1.05).clamp(0, 255);
       p.b = (p.b * 0.9).clamp(0, 255);
    }
    return result;
  }

  img.Image _applyCoolFilter(img.Image image) {
    final result = img.Image.from(image);
    for (var p in result) {
       p.r = (p.r * 0.9).clamp(0, 255);
       p.g = (p.g * 1.05).clamp(0, 255);
       p.b = (p.b * 1.2).clamp(0, 255);
    }
    return result;
  }

  img.Image _applyVintageFilter(img.Image image) {
    final result = img.Image.from(image);
    for (var p in result) {
       final r = p.r; final g = p.g; final b = p.b;
       p.r = (r * 0.393 + g * 0.769 + b * 0.189).clamp(0, 255);
       p.g = (r * 0.349 + g * 0.686 + b * 0.168).clamp(0, 255);
       p.b = (r * 0.272 + g * 0.534 + b * 0.131).clamp(0, 255);
    }
    return result;
  }

  img.Image _applyBlackAndWhiteFilter(img.Image image) {
    final result = img.Image.from(image);
    for (var p in result) {
       final gray = (p.r * 0.299 + p.g * 0.587 + p.b * 0.114).toInt().clamp(0, 255);
       p.r = gray; p.g = gray; p.b = gray;
    }
    return result;
  }

  img.Image _sharpenImage(img.Image image, double amount) {
    final result = img.Image.from(image);
    img.convolution(result, filter: [-1, -1, -1, -1, 9, -1, -1, -1, -1]);
    return result;
  }

  img.Image _resizeToFitContainer(img.Image image, {int? maxWidth, int? maxHeight, bool maintainAspectRatio = true}) {
    if (maxWidth == null && maxHeight == null) return image;
    return img.copyResize(image, width: maxWidth, height: maxHeight, interpolation: img.Interpolation.linear);
  }

  Future<String> _saveImage(img.Image image) async {
    final tempDir = await getTemporaryDirectory();
    final fileName = 'enhanced_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final filePath = '${tempDir.path}/$fileName';
    final jpgBytes = img.encodeJpg(image, quality: 90);
    await File(filePath).writeAsBytes(jpgBytes);
    return filePath;
  }
  
  void dispose() {}
}

class EnhancementOptions {
  final bool autoBalance;
  final bool faceEnhancement;
  final bool sharpen;
  final double sharpenAmount;
  final double brightness;
  final double contrast;
  final double saturation;
  final ImageFilter? filter;
  final FaceBeautyOptions faceBeautyOptions;
  final int? maxWidth;
  final int? maxHeight;
  final bool upscale;
  final double upscaleFactor;
  
  const EnhancementOptions({
    this.autoBalance = false,
    this.faceEnhancement = false,
    this.sharpen = false,
    this.sharpenAmount = 0.5,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.filter,
    this.faceBeautyOptions = const FaceBeautyOptions(),
    this.maxWidth,
    this.maxHeight,
    this.upscale = false,
    this.upscaleFactor = 1.0,
  });

  EnhancementOptions copyWith({
    bool? autoBalance, bool? faceEnhancement, bool? sharpen, double? sharpenAmount,
    double? brightness, double? contrast, double? saturation, ImageFilter? filter,
    FaceBeautyOptions? faceBeautyOptions, int? maxWidth, int? maxHeight, bool? upscale, double? upscaleFactor,
  }) {
    return EnhancementOptions(
      autoBalance: autoBalance ?? this.autoBalance,
      faceEnhancement: faceEnhancement ?? this.faceEnhancement,
      sharpen: sharpen ?? this.sharpen,
      sharpenAmount: sharpenAmount ?? this.sharpenAmount,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      filter: filter ?? this.filter,
      faceBeautyOptions: faceBeautyOptions ?? this.faceBeautyOptions,
      maxWidth: maxWidth ?? this.maxWidth,
      maxHeight: maxHeight ?? this.maxHeight,
      upscale: upscale ?? this.upscale,
      upscaleFactor: upscaleFactor ?? this.upscaleFactor,
    );
  }
}

class FaceBeautyOptions {
  final double skinSmooth;
  final double skinBrighten;
  final double eyeEnhance;
  final double teethWhiten;
  const FaceBeautyOptions({this.skinSmooth = 0.5, this.skinBrighten = 0.1, this.eyeEnhance = 0.3, this.teethWhiten = 0.2});
}

enum ImageFilter { warm, cool, vintage, blackAndWhite, dramatic, softGlow, portrait, hdr }

class _LocalAverage {
  final double r, g, b;
  _LocalAverage({required this.r, required this.g, required this.b});
}
