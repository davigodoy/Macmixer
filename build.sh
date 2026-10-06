#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Mixer.app"
ARCH="${MIXER_ARCH:-$(uname -m)}"
TARGET="$ARCH-apple-macosx14.2"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
xcrun --sdk macosx clang -target "$TARGET" -fobjc-arc \
  -c "$ROOT/Sources/MixerObjCBridge.m" \
  -o "$ROOT/build/MixerObjCBridge.o"

swiftc \
  -swift-version 5 \
  -target "$TARGET" \
  -O \
  -module-cache-path "$ROOT/build/ModuleCache" \
  -import-objc-header "$ROOT/Sources/MixerObjCBridge.h" \
  -framework AppKit \
  -framework AVFAudio \
  -framework SwiftUI \
  -framework CoreAudio \
  -framework ApplicationServices \
  -framework AudioToolbox \
  -framework ServiceManagement \
  "$ROOT/build/MixerObjCBridge.o" \
  "$ROOT/Sources/MixerApp.swift" \
  "$ROOT/Sources/CoreAudioMixer.swift" \
  "$ROOT/Sources/AudioAppGrouping.swift" \
  "$ROOT/Sources/MediaRemoteNowPlayingScanner.swift" \
  "$ROOT/Sources/AudioSourceMetadata.swift" \
  "$ROOT/Sources/SafariAudioTabScanner.swift" \
  "$ROOT/Sources/StereoPCM.swift" \
  -o "$APP/Contents/MacOS/Mixer"

if [[ "${MIXER_SIGNING:-local}" != "adhoc" && -f "$ROOT/build/Signing/Mixer.keychain-db" ]]; then
  "$ROOT/repair-signing.command" --sign-only
else
  xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
