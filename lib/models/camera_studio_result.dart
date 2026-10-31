import 'package:universal_io/io.dart';
import '../services/filter_catalogue_service.dart';

/// Returned by NecxaCameraCaptureScreen when recording is finished.
/// Contains the recorded video clip files, chosen filter metadata, and intensity.
class CameraStudioResult {
  final List<File> clips;
  final NecxaFilterMeta? filter;
  final double filterIntensity;

  const CameraStudioResult({
    required this.clips,
    this.filter,
    this.filterIntensity = 1.0,
  });

  bool get hasFilter => filter != null && !filter!.isNone;
}
