import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';

class ClipData {
  final String path;
  final double start;
  final double end;
  final double speed;
  final double volume;
  final bool isVideo;
  final bool hasAudio;
  final double scale;
  final double rotation;
  final double offsetX;
  final double offsetY;
  final double opacity;

  const ClipData({
    required this.path,
    required this.start,
    required this.end,
    this.speed = 1.0,
    this.volume = 1.0,
    this.isVideo = true,
    this.hasAudio = true,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.opacity = 1.0,
  });
}

class RenderOverlay {
  final String type;
  final String? text;
  final String? imagePath;
  final double start;
  final double end;
  final double x;
  final double y;
  final double scale;
  final double rotation;
  final double opacity;
  final double fontSize;
  final Color color;
  final Color background;
  final double backgroundOpacity;
  final bool shadow;

  const RenderOverlay({
    required this.type,
    this.text,
    this.imagePath,
    this.start = 0.0,
    this.end = 1.0,
    this.x = 0.5,
    this.y = 0.5,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.opacity = 1.0,
    this.fontSize = 28.0,
    this.color = Colors.white,
    this.background = Colors.black,
    this.backgroundOpacity = 0.0,
    this.shadow = true,
  });
}

class RenderEffects {
  final double brightness;
  final double contrast;
  final double saturation;
  final double hue;
  final double vignette;
  final double blur;
  final double grain;

  const RenderEffects({
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.hue = 0.0,
    this.vignette = 0.0,
    this.blur = 0.0,
    this.grain = 0.0,
  });
}

class RenderTransition {
  final int afterClipIndex;
  final String presetId;
  final double duration;

  const RenderTransition({
    required this.afterClipIndex,
    required this.presetId,
    this.duration = 0.6,
  });
}

class RenderAudioTrack {
  final String path;
  final double sourceStart;
  final double? sourceEnd;
  final double timelineStart;
  final double volume;
  final double speed;
  final bool reverse;

  const RenderAudioTrack({
    required this.path,
    this.sourceStart = 0,
    this.sourceEnd,
    this.timelineStart = 0,
    this.volume = 1,
    this.speed = 1,
    this.reverse = false,
  });
}

class VideoEnhancementService {
  /// Complete video enhancement pipeline
  Future<File> enhanceVideo({
    required File inputVideo,
    VideoEnhancementOptions options = const VideoEnhancementOptions(),
    void Function(double progress)? onProgress,
  }) async {
    if (!options.applyBeautyFilter &&
        !options.autoBalance &&
        !options.sharpen) {
      return inputVideo;
    }

    final outputPath = await _getOutputPath();
    List<String> filters = [];

    if (options.applyBeautyFilter) {
      // Apply edge-preserving blur (skin smoothing) and basic color correction
      filters.add("smartblur=lr=3:ls=-0.5:lt=0");
      filters.add("eq=brightness=0.03:saturation=1.1");
    }

    if (options.sharpen) {
      filters.add("unsharp=3:3:1.5");
    }

    String filterComplex = filters.isNotEmpty
        ? "-vf \"${filters.join(',')}\""
        : "";

    // -c:v libx264 -crf 26: High-efficiency "Smart" compression
    // -movflags +faststart: Instant play in social feeds
    String command =
        "-i '${_escapePath(inputVideo.path)}' $filterComplex -c:v libx264 -crf 26 -preset fast -c:a copy -movflags +faststart -y \"$outputPath\"";

    debugPrint('Executing FFmpeg enhance command: $command');
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      debugPrint('Video enhancement successful: $outputPath');
      return File(outputPath);
    } else {
      debugPrint('Video enhancement failed with code: $returnCode');
      return inputVideo; // Return original on failure
    }
  }

  Future<String> _getOutputPath() async {
    final tempDir = await getTemporaryDirectory();
    return '${tempDir.path}/vibe_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }

  /// Combine multiple clips into a single video file
  Future<File?> combineSequence({
    required List<ClipData> clips,
    required String aspectRatio,
    List<RenderOverlay> overlays = const [],
    List<RenderTransition> transitions = const [],
    List<RenderAudioTrack> audioTracks = const [],
    RenderEffects effects = const RenderEffects(),
    String? backgroundMusicPath,
    double musicStart = 0.0,
    double musicEnd = 30.0,
    double musicVolume = 1.0,
    double musicOffset = 0.0,
    String? voiceOverPath,
    double voiceOverVolume = 1.0,
  }) async {
    if (clips.isEmpty) return null;
    final outputPath = await _getOutputPath();

    // Order of inputs: [0..N-1] clips, then overlay images, BGM (optional), voice (optional), then silent source.
    String inputs = "";
    for (int i = 0; i < clips.length; i++) {
      inputs += "-i '${_escapePath(clips[i].path)}' ";
    }

    int nextIndex = clips.length;
    final imageOverlayIndexes = <int, int>{};
    for (int i = 0; i < overlays.length; i++) {
      final path = overlays[i].imagePath;
      if (path != null && path.isNotEmpty) {
        inputs += "-i '${_escapePath(path)}' ";
        imageOverlayIndexes[i] = nextIndex;
        nextIndex++;
      }
    }

    int? bgmIndex;
    if (backgroundMusicPath != null && backgroundMusicPath.isNotEmpty) {
      inputs += "-i '${_escapePath(backgroundMusicPath)}' ";
      bgmIndex = nextIndex;
      nextIndex++;
    }

    int? voiceIndex;
    if (voiceOverPath != null && voiceOverPath.isNotEmpty) {
      inputs += "-i '${_escapePath(voiceOverPath)}' ";
      voiceIndex = nextIndex;
      nextIndex++;
    }

    final audioTrackIndexes = <int, int>{};
    for (int i = 0; i < audioTracks.length; i++) {
      inputs += "-i '${_escapePath(audioTracks[i].path)}' ";
      audioTrackIndexes[i] = nextIndex++;
    }

    int silentIndex = nextIndex;
    String silentInput =
        "-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 ";

    String filterComplex = "";

    int targetWidth = 720;
    int targetHeight = 1280;

    if (aspectRatio == '1:1') {
      targetWidth = 720;
      targetHeight = 720;
    } else if (aspectRatio == '4:5') {
      targetWidth = 720;
      targetHeight = 900;
    }

    for (int i = 0; i < clips.length; i++) {
      final clip = clips[i];
      // Note: inputs are already added above in order.

      double duration = (clip.end - clip.start).abs();
      if (duration < 0.1) duration = 1.0; // Fallback for safety

      // 1. VIDEO NORMALIZATION
      // crop and scale logic
      // Calculate aspect ratio as a float to avoid integer division in FFmpeg expressions
      String cropFilter =
          "crop=min(iw\\,ih*($targetWidth.0/$targetHeight.0)):min(ih\\,iw*($targetHeight.0/$targetWidth.0))";

      // Calculate safe fade duration (max 0.3s or 10% of clip duration)
      double safeFade = (duration / clip.speed * 0.1).clamp(0.0, 0.3);
      double fadeOutStart = (duration / clip.speed) - safeFade;
      if (fadeOutStart < 0) fadeOutStart = 0;

      if (clip.isVideo) {
        filterComplex +=
            "[$i:v]trim=start=${clip.start}:end=${clip.end},setpts=${1.0 / clip.speed}*(PTS-STARTPTS),fps=30,format=yuv420p,$cropFilter,scale=$targetWidth:$targetHeight,setsar=1";
        filterComplex += _clipTransformFilter(clip, targetWidth, targetHeight);
        if (safeFade > 0.05) {
          filterComplex +=
              ",fade=t=in:st=0:d=$safeFade,fade=t=out:st=$fadeOutStart:d=$safeFade";
        }
        filterComplex += "[v$i];";
      } else {
        filterComplex +=
            "[$i:v]loop=loop=-1:size=1:start=0,trim=duration=$duration,setpts=PTS-STARTPTS,fps=30,format=yuv420p,$cropFilter,scale=$targetWidth:$targetHeight,setsar=1";
        filterComplex += _clipTransformFilter(clip, targetWidth, targetHeight);
        if (safeFade > 0.05) {
          filterComplex +=
              ",fade=t=in:st=0:d=$safeFade,fade=t=out:st=${duration - safeFade}:d=$safeFade";
        }
        filterComplex += "[v$i];";
      }

      // 2. AUDIO NORMALIZATION
      // If speed is not 1.0, we need to handle atempo (0.5 to 2.0 limit)
      String speedFilter = "";
      if (clip.speed != 1.0) {
        double s = clip.speed;
        while (s > 2.0) {
          speedFilter += "atempo=2.0,";
          s /= 2.0;
        }
        while (s < 0.5) {
          speedFilter += "atempo=0.5,";
          s /= 0.5;
        }
        speedFilter += "atempo=$s";
      } else {
        speedFilter = "anull";
      }

      if (clip.isVideo && clip.hasAudio) {
        // Use [i:a] if available, otherwise use silence
        // We use amix with silence to ensure an audio stream exists even if input has none
        filterComplex +=
            "[$i:a]atrim=start=${clip.start}:end=${clip.end},asetpts=PTS-STARTPTS,$speedFilter,volume=${clip.volume},aresample=44100,aformat=channel_layouts=stereo[a_orig_$i];";
        // Mix with a slice of silence for extreme robustness
        filterComplex +=
            "[$silentIndex:a]atrim=duration=${duration / clip.speed},asetpts=PTS-STARTPTS[silence$i];";
        filterComplex +=
            "[a_orig_$i][silence$i]amix=inputs=2:duration=first[a$i];";
      } else {
        // Images or audio-less videos get silence
        filterComplex +=
            "[$silentIndex:a]atrim=duration=${duration / clip.speed},asetpts=PTS-STARTPTS,volume=0[a$i];";
      }
    }

    if (clips.length > 1 && transitions.isNotEmpty) {
      var videoLabel = 'v0';
      var audioLabel = 'a0';
      var elapsed =
          (clips.first.end - clips.first.start).abs() / clips.first.speed;
      for (int i = 1; i < clips.length; i++) {
        final transition = _transitionAfter(transitions, i - 1);
        final requested = transition?.duration ?? 0.001;
        final nextDuration =
            (clips[i].end - clips[i].start).abs() / clips[i].speed;
        final maxDuration = math.max(
          0.001,
          math.min(elapsed, nextDuration) / 2,
        );
        final duration = requested.clamp(0.001, maxDuration);
        final offset = (elapsed - duration).clamp(0.0, double.infinity);
        final nextVideo = i == clips.length - 1 ? 'outv' : 'vx$i';
        final nextAudio = i == clips.length - 1 ? 'outa_orig' : 'ax$i';
        filterComplex +=
            "[$videoLabel][v$i]xfade=transition=${_ffmpegTransition(transition?.presetId)}:duration=$duration:offset=$offset[$nextVideo];";
        filterComplex +=
            "[$audioLabel][a$i]acrossfade=d=$duration:c1=tri:c2=tri[$nextAudio];";
        videoLabel = nextVideo;
        audioLabel = nextAudio;
        elapsed += nextDuration - duration;
      }
    } else if (clips.length > 1) {
      final concatParts = List.generate(
        clips.length,
        (index) => '[v$index][a$index]',
      ).join();
      filterComplex +=
          "${concatParts}concat=n=${clips.length}:v=1:a=1[outv][outa_orig];";
    } else {
      filterComplex += "[v0]copy[outv];[a0]acopy[outa_orig];";
    }

    String currentVideo = "outv";
    final visualFilters = _globalVisualFilters(
      effects,
      targetWidth,
      targetHeight,
    );
    if (visualFilters.isNotEmpty) {
      filterComplex += "[$currentVideo]$visualFilters[visual_base];";
      currentVideo = "visual_base";
    }

    for (int i = 0; i < overlays.length; i++) {
      final overlay = overlays[i];
      final nextLabel = "ov$i";
      final timelineDuration = _timelineDuration(clips);
      final startTime = overlay.start
          .clamp(0.0, timelineDuration)
          .toStringAsFixed(3);
      final endTime = overlay.end
          .clamp(0.0, timelineDuration)
          .toStringAsFixed(3);
      if (overlay.imagePath != null && imageOverlayIndexes[i] != null) {
        final imageLabel = "imgov$i";
        final width = (targetWidth * 0.28 * overlay.scale)
            .clamp(32.0, targetWidth.toDouble())
            .toStringAsFixed(0);
        final rotate = overlay.rotation.abs() > 0.001
            ? ",rotate=${overlay.rotation}:c=none:ow=rotw(iw):oh=roth(ih)"
            : "";
        filterComplex +=
            "[${imageOverlayIndexes[i]}:v]format=rgba,scale=$width:-1$rotate,colorchannelmixer=aa=${overlay.opacity.clamp(0.0, 1.0)}[$imageLabel];";
        filterComplex +=
            "[$currentVideo][$imageLabel]overlay=x='(W-w)*${overlay.x.clamp(0.0, 1.0)}':y='(H-h)*${overlay.y.clamp(0.0, 1.0)}':enable='between(t,$startTime,$endTime)'[$nextLabel];";
      } else if ((overlay.text ?? '').trim().isNotEmpty) {
        final text = _escapeDrawText(overlay.text!.trim());
        final fontSize = (overlay.fontSize * overlay.scale)
            .clamp(10.0, 96.0)
            .toStringAsFixed(0);
        final fontColor = _ffmpegColor(overlay.color, overlay.opacity);
        final boxColor = _ffmpegColor(
          overlay.background,
          overlay.backgroundOpacity,
        );
        final shadow = overlay.shadow
            ? ":shadowcolor=black@0.65:shadowx=2:shadowy=2"
            : "";
        final xExpr = "(w-text_w)*${overlay.x.clamp(0.0, 1.0)}";
        final yExpr = "(h-text_h)*${overlay.y.clamp(0.0, 1.0)}";
        filterComplex +=
            "[$currentVideo]drawtext=text='$text':x='$xExpr':y='$yExpr':fontsize=$fontSize:fontcolor=$fontColor:box=1:boxcolor=$boxColor:boxborderw=12$shadow:enable='between(t,$startTime,$endTime)'[$nextLabel];";
      } else {
        continue;
      }
      currentVideo = nextLabel;
    }

    // 3. MIXING ALL AUDIO SOURCES
    String audioSources = "[outa_orig]";
    int inputsCount = 1;

    if (bgmIndex != null) {
      int delayMs = (musicOffset * 1000).toInt();
      filterComplex +=
          "[$bgmIndex:a]atrim=start=$musicStart:end=$musicEnd,asetpts=PTS-STARTPTS,volume=$musicVolume,aresample=44100,aformat=channel_layouts=stereo,adelay=$delayMs|$delayMs[bgm];";
      audioSources += "[bgm]";
      inputsCount++;
    }

    if (voiceIndex != null) {
      filterComplex +=
          "[$voiceIndex:a]volume=$voiceOverVolume,aresample=44100,aformat=channel_layouts=stereo[voice];";
      audioSources += "[voice]";
      inputsCount++;
    }

    for (int i = 0; i < audioTracks.length; i++) {
      final track = audioTracks[i];
      final index = audioTrackIndexes[i]!;
      final label = 'timeline_audio_$i';
      final trimEnd = track.sourceEnd == null ? '' : ':end=${track.sourceEnd}';
      final reverse = track.reverse ? ',areverse' : '';
      final tempo = _atempoFilter(track.speed);
      final delay = (track.timelineStart * 1000).round().clamp(0, 1 << 31);
      filterComplex +=
          "[$index:a]atrim=start=${track.sourceStart}$trimEnd,asetpts=PTS-STARTPTS,$tempo$reverse,volume=${track.volume},aresample=44100,aformat=channel_layouts=stereo,adelay=$delay|$delay[$label];";
      audioSources += '[$label]';
      inputsCount++;
    }

    if (inputsCount > 1) {
      filterComplex +=
          "${audioSources}amix=inputs=$inputsCount:duration=first:dropout_transition=2[outa]";
    } else {
      filterComplex += "[outa_orig]anull[outa]";
    }

    // libx264 -crf 26: The "Economical" compression sweet spot
    // -maxrate 2.5M: Prevents bitrate spikes on mobile data
    String command =
        "$inputs $silentInput -filter_complex \"$filterComplex\" -map \"[$currentVideo]\" -map \"[outa]\" -c:v libx264 -crf 26 -maxrate 2.5M -bufsize 5M -c:a aac -preset fast -pix_fmt yuv420p -movflags +faststart -y \"$outputPath\"";

    debugPrint('Executing smarter FFmpeg command: $command');
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      debugPrint('FFmpeg SUCCESS: Master file generated at $outputPath');
      return File(outputPath);
    } else if (ReturnCode.isCancel(returnCode)) {
      debugPrint('FFmpeg CANCELLED');
      return null;
    } else {
      final logs = await session.getAllLogsAsString();
      debugPrint('FFmpeg ERROR (Code: $returnCode): $logs');
      return null;
    }
  }

  /// Mix background music with video while keeping original audio (ducked)
  Future<File> mixMusicWithVideo({
    required File inputVideo,
    required File musicFile,
    double musicVolume = 0.4,
    double originalVolume = 0.8,
  }) async {
    return inputVideo;
  }

  String _escapePath(String path) {
    // Escape single quotes for FFmpeg command line
    return path.replaceAll("'", "'\\''");
  }

  String _atempoFilter(double speed) {
    var remaining = speed.clamp(0.125, 8.0).toDouble();
    final filters = <String>[];
    while (remaining > 2) {
      filters.add('atempo=2.0');
      remaining /= 2;
    }
    while (remaining < 0.5) {
      filters.add('atempo=0.5');
      remaining /= 0.5;
    }
    filters.add('atempo=$remaining');
    return filters.join(',');
  }

  RenderTransition? _transitionAfter(
    List<RenderTransition> transitions,
    int index,
  ) {
    for (final transition in transitions) {
      if (transition.afterClipIndex == index) return transition;
    }
    return null;
  }

  String _ffmpegTransition(String? presetId) {
    switch (presetId?.toLowerCase()) {
      case 'fade':
      case 'crossfade':
      case 'dissolve':
        return 'fade';
      case 'slide':
        return 'slideleft';
      case 'wipe':
        return 'wipeleft';
      case 'zoom':
        return 'zoomin';
      case 'blur':
        return 'smoothleft';
      default:
        return 'fade';
    }
  }

  double _timelineDuration(List<ClipData> clips) {
    return clips
        .fold(0.0, (sum, clip) {
          final duration = (clip.end - clip.start).abs();
          return sum + (duration < 0.1 ? 1.0 : duration) / clip.speed;
        })
        .clamp(0.1, double.infinity)
        .toDouble();
  }

  String _clipTransformFilter(
    ClipData clip,
    int targetWidth,
    int targetHeight,
  ) {
    final filters = <String>[];
    if ((clip.scale - 1.0).abs() > 0.01) {
      final scaledW = (targetWidth * clip.scale).round();
      final scaledH = (targetHeight * clip.scale).round();
      filters.add("scale=$scaledW:$scaledH");
      filters.add("crop=$targetWidth:$targetHeight");
    }
    if (clip.rotation.abs() > 0.001) {
      filters.add(
        "rotate=${clip.rotation}:ow=$targetWidth:oh=$targetHeight:c=black@0",
      );
    }
    if (clip.offsetX.abs() > 0.1 || clip.offsetY.abs() > 0.1) {
      final x = clip.offsetX.round();
      final y = clip.offsetY.round();
      filters.add(
        "pad=${targetWidth + x.abs() * 2}:${targetHeight + y.abs() * 2}:${x.abs() + x}:${y.abs() + y}:black",
      );
      filters.add("crop=$targetWidth:$targetHeight");
    }
    if (clip.opacity < 0.99) {
      filters.add(
        "format=rgba,colorchannelmixer=aa=${clip.opacity.clamp(0.0, 1.0)},format=yuv420p",
      );
    }
    return filters.isEmpty ? "" : ",${filters.join(',')}";
  }

  String _globalVisualFilters(RenderEffects effects, int width, int height) {
    final filters = <String>[];
    if (effects.brightness.abs() > 0.001 ||
        (effects.contrast - 1.0).abs() > 0.001 ||
        (effects.saturation - 1.0).abs() > 0.001) {
      filters.add(
        "eq=brightness=${effects.brightness}:contrast=${effects.contrast}:saturation=${effects.saturation}",
      );
    }
    if (effects.hue.abs() > 0.001) {
      filters.add("hue=h=${effects.hue}");
    }
    if (effects.blur > 0.05) {
      filters.add(
        "boxblur=${effects.blur.clamp(0.0, 8.0).toStringAsFixed(1)}:1",
      );
    }
    if (effects.grain > 0.01) {
      final strength = (effects.grain * 18).clamp(1.0, 24.0).toStringAsFixed(1);
      filters.add("noise=alls=$strength:allf=t");
    }
    if (effects.vignette > 0.01) {
      filters.add("vignette=PI/4");
    }
    return filters.join(",");
  }

  String _ffmpegColor(Color color, double opacity) {
    // ignore: deprecated_member_use
    final hex = color.value.toRadixString(16).padLeft(8, '0').substring(2);
    return "0x$hex@${opacity.clamp(0.0, 1.0).toStringAsFixed(2)}";
  }

  String _escapeDrawText(String text) {
    return text
        .replaceAll("\\", "\\\\")
        .replaceAll(":", "\\:")
        .replaceAll("'", "\\'")
        .replaceAll("%", "\\%")
        .replaceAll("\n", r"\n");
  }

  /// PROXY ENGINE: Generate a lightweight 540p proxy for smooth editing
  Future<File> generateProxy(File inputVideo) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath =
        '${tempDir.path}/proxy_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // -vf "scale=-2:540": Scales to 540p height while maintaining aspect ratio (must be even for libx264)
    // -preset ultrafast: Maximum speed for proxy generation
    // -crf 28: Lower quality is acceptable for proxy
    String command =
        "-i '${_escapePath(inputVideo.path)}' -vf \"scale=-2:540\" -c:v libx264 -preset ultrafast -crf 28 -c:a aac -b:a 64k -y \"$outputPath\"";

    debugPrint('Generating Proxy: $command');
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      return File(outputPath);
    } else {
      debugPrint('Proxy generation failed, falling back to original');
      return inputVideo;
    }
  }
}

class VideoEnhancementOptions {
  final bool applyBeautyFilter;
  final bool autoBalance;
  final bool sharpen;
  final Size? upscaleTo;
  final bool frameInterpolation;
  final bool enhanceThumbnail;

  const VideoEnhancementOptions({
    this.applyBeautyFilter = false,
    this.autoBalance = false,
    this.sharpen = false,
    this.upscaleTo,
    this.frameInterpolation = false,
    this.enhanceThumbnail = false,
  });
}
