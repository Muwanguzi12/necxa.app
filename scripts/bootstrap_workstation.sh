#!/usr/bin/env bash
# =============================================================================
#  Necxa Technology Ltd — Cloud Workstation Bootstrap Script
#  Run once inside the workstation terminal to set up the full dev environment.
#  Usage:  bash ~/necxa_flutter/scripts/bootstrap_workstation.sh
# =============================================================================
set -euo pipefail

FLUTTER_VERSION="stable"
NODE_VERSION="20"
REPO_URL="https://github.com/Muwanguzi12/necxa.app.git"
REPO_DIR="$HOME/necxa_flutter"
FLUTTER_DIR="$HOME/flutter"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Necxa Technology Ltd — Workstation Setup         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. System packages ───────────────────────────────────────────────────────
echo "▶ [1/8] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  curl git unzip xz-utils zip libglu1-mesa \
  openjdk-17-jdk wget clang cmake ninja-build \
  libgtk-3-dev pkg-config liblzma-dev \
  android-sdk-build-tools

# ── 2. Flutter SDK ────────────────────────────────────────────────────────────
echo "▶ [2/8] Installing Flutter SDK ($FLUTTER_VERSION)..."
if [ ! -d "$FLUTTER_DIR" ]; then
  git clone https://github.com/flutter/flutter.git \
    --depth=1 -b "$FLUTTER_VERSION" "$FLUTTER_DIR"
fi

# Add Flutter to PATH permanently
if ! grep -q 'flutter/bin' "$HOME/.bashrc"; then
  echo "export PATH=\"\$PATH:$FLUTTER_DIR/bin\"" >> "$HOME/.bashrc"
fi
export PATH="$PATH:$FLUTTER_DIR/bin"

flutter precache
echo "✅ Flutter $(flutter --version | head -1) installed"

# ── 3. Android SDK ────────────────────────────────────────────────────────────
echo "▶ [3/8] Setting up Android SDK..."
ANDROID_SDK_ROOT="$HOME/android-sdk"
mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
if [ ! -d "$ANDROID_SDK_ROOT/cmdline-tools/latest" ]; then
  wget -q "$CMDLINE_TOOLS_URL" -O /tmp/cmdline-tools.zip
  unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"
  mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" \
     "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  rm /tmp/cmdline-tools.zip
fi

export ANDROID_SDK_ROOT
export PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools"

if ! grep -q 'ANDROID_SDK_ROOT' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" << 'BASHRC'
export ANDROID_SDK_ROOT="$HOME/android-sdk"
export PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools"
BASHRC
fi

# Accept all Android licenses & install required packages
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager \
  "platform-tools" \
  "platforms;android-35" \
  "build-tools;35.0.0" \
  "ndk;27.0.12077973" > /dev/null 2>&1
echo "✅ Android SDK installed (API 35, NDK 27)"

# ── 4. Flutter Android setup ──────────────────────────────────────────────────
echo "▶ [4/8] Configuring Flutter for Android..."
flutter config --android-sdk "$ANDROID_SDK_ROOT"
yes | flutter doctor --android-licenses > /dev/null 2>&1 || true

# ── 5. Node.js + global tools ─────────────────────────────────────────────────
echo "▶ [5/8] Installing Node.js $NODE_VERSION + global dev tools..."
if ! command -v node &>/dev/null; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash - -qq
  sudo apt-get install -y -qq nodejs
fi

npm install -g --silent \
  firebase-tools \
  wrangler \
  @supabase/cli

echo "✅ Node $(node --version), npm $(npm --version)"
echo "✅ Firebase CLI $(firebase --version)"
echo "✅ Wrangler $(wrangler --version)"

# ── 6. Clone / update the repo ────────────────────────────────────────────────
echo "▶ [6/8] Setting up Necxa repository..."
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
else
  git -C "$REPO_DIR" pull --rebase origin main
fi

# Git identity
git config --global user.email "muwanguzi@necxa.uk"
git config --global user.name "Muwanguzi12"
git config --global pull.rebase true
echo "✅ Repo ready at $REPO_DIR (branch: $(git -C "$REPO_DIR" branch --show-current))"

# ── 7. Flutter pub get ────────────────────────────────────────────────────────
echo "▶ [7/8] Fetching Flutter dependencies..."
cd "$REPO_DIR"
flutter pub get
echo "✅ Dependencies resolved"

# ── 8. Final health check ──────────────────────────────────────────────────────
echo ""
echo "▶ [8/8] Running flutter doctor..."
flutter doctor -v

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           ✅  Bootstrap complete!  Happy coding!          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  cd ~/necxa_flutter                                      ║"
echo "║  flutter build apk --release --split-per-abi            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
