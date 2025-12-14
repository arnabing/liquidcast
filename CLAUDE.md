# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

Open `LiquidCast.xcodeproj` in Xcode 15+ and build:
- **macOS target**: `LiquidCast (macOS)` - requires macOS 13.0+ (Ventura)
- **iOS target**: `LiquidCast (iOS)` - requires iOS 16.0+

From command line:
```bash
# Build macOS
xcodebuild -project LiquidCast.xcodeproj -scheme "LiquidCast (macOS)" -configuration Debug build

# Build iOS (simulator)
xcodebuild -project LiquidCast.xcodeproj -scheme "LiquidCast (iOS)" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## Architecture Overview

LiquidCast is a native macOS/iOS app for casting media to Apple TV via AirPlay. The codebase follows a shared-first architecture with platform-specific extensions.

### Core Components

**AppState** (`Shared/Models/AppState.swift`)
- Central `@MainActor` observable state container injected as `@EnvironmentObject`
- Orchestrates all services: `MediaPlayerController`, `AirPlayManager`, `TranscodeManager`
- All media loading goes through `loadMedia()` which routes to TranscodeManager for codec detection
- Handles cache cleanup when playback reaches 80% (removes converted files automatically)
- Persists last device, casting mode, and compatibility mode via UserDefaults

**MediaPlayerController** (`Shared/MediaPlayer/MediaPlayerController.swift`)
- AVPlayer wrapper with `allowsExternalPlayback = true` for native AirPlay streaming
- Prevents system sleep during playback (IOKit on macOS, ProcessInfo on iOS)
- Publishes playback state and progress via callbacks

**TranscodeManager** (`Shared/Transcoder/TranscodeManager.swift`)
- Base class with platform-specific implementations via extensions
- **macOS** (`macOS/Transcoder/TranscodeManagerMacOS.swift`): Uses FFmpeg with 3 conversion paths:
  - **Path 1**: Direct playback - H.264 + compatible profile + AAC → returns original URL (no conversion)
  - **Path 2**: HLS with video copy - H.264 + incompatible audio (AC3/DTS) → copy video, transcode audio
  - **Path 3**: Full HLS transcode - non-H.264 or High profile on Smart TV → hardware transcode via VideoToolbox
- **iOS** (`iOS/Transcoder/TranscodeManageriOS.swift`): Stub that throws - iOS only supports native formats

**LocalHTTPServer** (`Shared/HTTPServer/LocalHTTPServer.swift`)
- Lightweight HTTP server using Network.framework (no external dependencies)
- Required because AirPlay needs http:// URLs - file:// doesn't work for remote playback
- Serves HLS playlist and .ts segments on ports 8765-8769

**CacheManager** (`Shared/Utils/CacheManager.swift`)
- Manages converted file storage in app's cache directory
- Auto-cleans files older than 7 days on app launch

**CompatibilityMode** (in `AppState.swift`)
- `appleTV`: Allows H.264 High profile (best quality)
- `smartTV`: Requires H.264 Main/Baseline profile (wider compatibility)
- Auto-detected from device name

### Platform Compilation

Uses `#if os(macOS)` / `#if os(iOS)` for platform-specific code:
- macOS-only: ScreenCaptureKit window capture, FFmpeg transcoding, LocalHTTPServer
- iOS-only: DocumentPicker for Files app integration, different sleep prevention API

### UI Pattern

SwiftUI views use "liquid glass" aesthetic with `.ultraThinMaterial` backgrounds. Main entry is `ContentView.swift` which branches to platform-specific views (`macOSContentView`, `iOSContentView`).

## Key Dependencies

- **FFmpeg** (macOS only): Required for transcoding non-native formats. Install with `brew install ffmpeg`. Searched at `/opt/homebrew/bin/ffmpeg` (Apple Silicon) or `/usr/local/bin/ffmpeg` (Intel).
- No Swift Package Manager dependencies - uses only Apple frameworks (AVFoundation, AVKit, ScreenCaptureKit, VideoToolbox, Network)

## Permissions

macOS requires Screen Recording permission for window capture mode (System Preferences → Privacy & Security → Screen Recording).
