# Necxa Studio FFmpeg runtime (Android)

Necxa's existing Flutter FFmpegKit bridge remains the single Dart/native integration. This change replaces the Android native AAR at build time; it does not add a second FFmpeg plugin or change media-renderer call sites.

## Pinned native runtime

- Rescue repository: https://github.com/Muwanguzi12/necxa-ffmpeg-rescue
- Source commit: `c72e151c1ba5bd6ce602a1dfd5eae402095bae86`
- Build profile: `necxa-studio-editor-gpl`
- Build run: https://github.com/Muwanguzi12/necxa-ffmpeg-rescue/actions/runs/42897254654
- Artifact ID: `13803900476`
- Artifact expires: 2027-02-08 (GitHub Actions artifact retention)
- AAR SHA-256: `8ef890bec420c90ae30dc1bb3a2aacf9dd47fdf90a238bcafa67c54207f4f85b`
- AAR: `ffmpeg-kit-min-gpl-6.0.3.aar`

The installer verifies both the downloaded ZIP and the AAR before replacing either tracked copy:
- `android/app/libs/ffmpeg-kit-min-gpl-6.0.3.aar`
- `plugins/ffmpeg_kit_flutter_min_gpl/android/libs/ffmpeg-kit-min-gpl-6.0.3.aar`

## CI credential prerequisite

The Android build job calls `scripts/install-necxa-ffmpeg.sh`. Add a repository Actions secret named `NECXA_FFMPEG_READ_TOKEN` to `Muwanguzi12/necxa.app`.

Use a fine-grained token scoped only to `Muwanguzi12/necxa-ffmpeg-rescue` with **Actions: read-only** permission. The token is passed only to the installer step and is not written to files or logs. Do not commit a token.

If this secret is absent or the artifact/checksum is invalid, the Android build intentionally fails rather than silently shipping the old runtime.

The artifact is temporary. Before 2027-02-08, produce a fresh verified artifact and update the pinned artifact ID and both checksums here and in the installer, or replace this interim artifact-download mechanism with a durable, versioned release distribution.

## Scope and validation

- This is an Android AAR only. It does not replace or validate iOS/macOS FFmpeg frameworks.
- The app's existing FFmpegKit Dart wrapper and renderer call sites are unchanged.
- A successful native AAR build and checksum verification do not prove each filter works on a device. Run Android smoke tests for H.264 encode, drawtext/subtitles, chromakey, overlay/xfade, and audio mixing/muxing; then verify Feed and Shop playback.
- This profile enables GPL and x264. Review GPL distribution obligations and codec patent/licensing implications before shipping the app to users.
