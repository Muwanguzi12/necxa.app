#!/usr/bin/env bash
set -euo pipefail

# Fetch the pinned Necxa Studio FFmpegKit AAR from the successful rescue build.
# The token must have Actions: read access to Muwanguzi12/necxa-ffmpeg-rescue.
: "${NECXA_FFMPEG_READ_TOKEN:?Set NECXA_FFMPEG_READ_TOKEN with Actions: read access to the rescue repository}"

readonly REPO="Muwanguzi12/necxa-ffmpeg-rescue"
readonly ARTIFACT_ID="13803900476"
readonly EXPECTED_ZIP_SHA256="dfc7b9b207d227c4cc95b9c9b25f34ae3ba4a4034407da4dc2085de29697cda3"
readonly EXPECTED_AAR_SHA256="8ef890bec420c90ae30dc1bb3a2aacf9dd47fdf90a238bcafa67c54207f4f85b"
readonly AAR_NAME="ffmpeg-kit-min-gpl-6.0.3.aar"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading pinned FFmpeg artifact $ARTIFACT_ID from $REPO"
curl --fail --silent --show-error --location \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $NECXA_FFMPEG_READ_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" \
  --output "$TMP_DIR/ffmpeg-artifact.zip"

echo "$EXPECTED_ZIP_SHA256  $TMP_DIR/ffmpeg-artifact.zip" | sha256sum --check
unzip -q "$TMP_DIR/ffmpeg-artifact.zip" -d "$TMP_DIR/unpacked"

AAR_PATH="$(find "$TMP_DIR/unpacked" -type f -name "$AAR_NAME" -print -quit)"
if [[ -z "$AAR_PATH" ]]; then
  echo "Expected $AAR_NAME was not found in the downloaded artifact." >&2
  exit 1
fi

echo "$EXPECTED_AAR_SHA256  $AAR_PATH" | sha256sum --check
unzip -tq "$AAR_PATH"

# Stage both copies first, then atomically replace the tracked AARs.
APP_LIB="$ROOT_DIR/android/app/libs"
PLUGIN_LIB="$ROOT_DIR/plugins/ffmpeg_kit_flutter_min_gpl/android/libs"
mkdir -p "$APP_LIB" "$PLUGIN_LIB"
install -m 0644 "$AAR_PATH" "$APP_LIB/$AAR_NAME.tmp"
install -m 0644 "$AAR_PATH" "$PLUGIN_LIB/$AAR_NAME.tmp"
mv "$APP_LIB/$AAR_NAME.tmp" "$APP_LIB/$AAR_NAME"
mv "$PLUGIN_LIB/$AAR_NAME.tmp" "$PLUGIN_LIB/$AAR_NAME"

echo "Installed verified Necxa Studio FFmpegKit AAR in both existing project locations."
