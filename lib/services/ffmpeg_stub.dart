// Web stub for FFmpeg — all operations return graceful no-ops on web.
// This file is imported instead of the native ffmpeg_kit_flutter_min_gpl
// package when building for web targets.

class ReturnCode {
  final int value;
  const ReturnCode(this.value);
  static bool isSuccess(ReturnCode? code) => false;
  static bool isCancel(ReturnCode? code) => false;
}

class Session {
  Future<ReturnCode?> getReturnCode() async => null;
  Future<String?> getAllLogsAsString() async => 'FFmpeg not available on web';
}

class FFmpegKit {
  static Future<Session> execute(String command) async {
    return Session();
  }
}

class MediaInformation {
  String? getDuration() => null;
  List<StreamInformation> getStreams() => [];
}

class StreamInformation {
  String? getType() => null;
}

class FFprobeSession {
  MediaInformation? getMediaInformation() => null;
}

class FFprobeKit {
  static Future<FFprobeSession> getMediaInformation(String path) async {
    return FFprobeSession();
  }
}
