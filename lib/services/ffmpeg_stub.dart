// Web/stub shim for FFmpeg — all operations return graceful no-ops on web.
// This file is imported instead of the native ffmpeg_kit_flutter_min_gpl
// package when building for web targets.
//
// Keep this in sync with the real plugin API (v6.0.3) so that conditional
// imports compile cleanly on all platforms.

class ReturnCode {
  static const int successCode = 0;
  static const int cancelCode = 255;

  final int _value;
  const ReturnCode(this._value);

  static bool isSuccess(ReturnCode? returnCode) =>
      returnCode?._value == ReturnCode.successCode;

  static bool isCancel(ReturnCode? returnCode) =>
      returnCode?._value == ReturnCode.cancelCode;

  int getValue() => _value;
  bool isValueSuccess() => _value == ReturnCode.successCode;
  bool isValueError() =>
      (_value != ReturnCode.successCode) && (_value != ReturnCode.cancelCode);
  bool isValueCancel() => _value == ReturnCode.cancelCode;

  @override
  String toString() => _value.toString();
}

class Statistics {
  final int sessionId;
  final int videoFrameNumber;
  final double videoFps;
  final double videoQuality;
  final int size;
  final int time;
  final double bitrate;
  final double speed;

  const Statistics(
    this.sessionId,
    this.videoFrameNumber,
    this.videoFps,
    this.videoQuality,
    this.size,
    this.time,
    this.bitrate,
    this.speed,
  );
}

class FFmpegSession {
  Future<ReturnCode?> getReturnCode() async => null;
  Future<String?> getAllLogsAsString() async => 'FFmpeg not available on web';
  Future<List<Statistics>> getStatistics() async => [];
  int getSessionId() => 0;
}

class FFmpegKit {
  static Future<FFmpegSession> execute(String command) async {
    return FFmpegSession();
  }

  static Future<FFmpegSession> executeWithArguments(
    List<String> commandArguments,
  ) async {
    return FFmpegSession();
  }

  static Future<FFmpegSession> executeAsync(
    String command, [
    Function? completeCallback,
    Function? logCallback,
    Function? statisticsCallback,
  ]) async {
    return FFmpegSession();
  }

  static Future<void> cancel([int? sessionId]) async {}

  static Future<List<FFmpegSession>> listSessions() async => [];
}

class MediaInformation {
  String? getDuration() => null;
  List<StreamInformation> getStreams() => [];
  Map<String, dynamic>? getAllProperties() => null;
}

class StreamInformation {
  String? getType() => null;
  String? getCodec() => null;
  int? getWidth() => null;
  int? getHeight() => null;
}

class MediaInformationSession {
  MediaInformation? getMediaInformation() => null;
  Future<ReturnCode?> getReturnCode() async => null;
}

class FFprobeKit {
  static Future<MediaInformationSession> getMediaInformation(
    String path,
  ) async {
    return MediaInformationSession();
  }

  static Future<MediaInformationSession> getMediaInformationAsync(
    String path, [
    Function? completeCallback,
  ]) async {
    return MediaInformationSession();
  }
}

class FFmpegKitConfig {
  static Future<void> init() async {}
  static Future<void> enableRedirection() async {}
  static Future<void> disableRedirection() async {}
  static Future<void> setLogLevel(int level) async {}
  static List<String> parseArguments(String command) => command.split(' ');
  static Future<void> ffmpegExecute(FFmpegSession session) async {}
  static Future<void> asyncFFmpegExecute(FFmpegSession session) async {}
}

class Level {
  static const int avLogTrace = 56;
  static const int avLogDebug = 48;
  static const int avLogVerbose = 40;
  static const int avLogInfo = 32;
  static const int avLogWarning = 24;
  static const int avLogError = 16;
  static const int avLogFatal = 8;
  static const int avLogPanic = 0;
  static const int avLogStderr = -16;
  static const int avLogQuiet = -8;
}
