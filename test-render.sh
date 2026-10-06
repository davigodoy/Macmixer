#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_BINARY="${TMPDIR:-/tmp}/MixerStereoPCMTests-$$"
BRIDGE_TEST_BINARY="${TMPDIR:-/tmp}/MixerObjCBridgeTests-$$"
SAFARI_AX_TEST_BINARY="${TMPDIR:-/tmp}/MixerSafariAXTests-$$"
mkdir -p "$ROOT/build"
xcrun --sdk macosx clang -fobjc-arc \
  -c "$ROOT/Sources/MixerObjCBridge.m" \
  -o "$ROOT/build/MixerObjCBridgeTests.o"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/build/TestModuleCache" \
  -import-objc-header "$ROOT/Sources/MixerObjCBridge.h" \
  -framework Foundation \
  -framework AVFAudio \
  -framework AudioToolbox \
  "$ROOT/build/MixerObjCBridgeTests.o" \
  "$ROOT/Sources/StereoPCM.swift" \
  "$ROOT/Sources/AudioAppGrouping.swift" \
  "$ROOT/Tests/StereoPCMTests.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/build/TestModuleCache" \
  -parse-as-library \
  -import-objc-header "$ROOT/Sources/MixerObjCBridge.h" \
  -framework Foundation \
  -framework AVFAudio \
  "$ROOT/build/MixerObjCBridgeTests.o" \
  "$ROOT/Tests/ExceptionBridgeTests.swift" \
  -o "$BRIDGE_TEST_BINARY"
"$BRIDGE_TEST_BINARY"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/build/TestModuleCache" \
  -framework AppKit \
  -framework ApplicationServices \
  "$ROOT/Sources/SafariAudioTabScanner.swift" \
  "$ROOT/Tests/SafariAudioTabScannerTests.swift" \
  -o "$SAFARI_AX_TEST_BINARY"
"$SAFARI_AX_TEST_BINARY"

NOW_PLAYING_TEST_BINARY="${TMPDIR:-/tmp}/MixerNowPlayingTests-$$"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/build/TestModuleCache" \
  -parse-as-library \
  -import-objc-header "$ROOT/Sources/MixerObjCBridge.h" \
  -framework Foundation -framework AVFAudio -framework ApplicationServices \
  "$ROOT/build/MixerObjCBridgeTests.o" \
  "$ROOT/Sources/MediaRemoteNowPlayingScanner.swift" \
  "$ROOT/Sources/AudioSourceMetadata.swift" \
  "$ROOT/Sources/SafariAudioTabScanner.swift" \
  "$ROOT/Tests/NowPlayingSourceTests.swift" \
  -o "$NOW_PLAYING_TEST_BINARY"
"$NOW_PLAYING_TEST_BINARY"

