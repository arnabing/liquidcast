# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Build Commands

```bash
# Build macOS
xcodebuild -project LiquidCast.xcodeproj -scheme "LiquidCast (macOS)" -configuration Debug build

# Build iOS (simulator)
xcodebuild -project LiquidCast.xcodeproj -scheme "LiquidCast (iOS)" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## Architecture Overview

LiquidCast is a macOS app for casting any video format to Apple TV via AirPlay. It uses FFmpeg to transcode incompatible formats and streams via HLS.

### App Entry Point

**`LiquidCastApp.swift`**
- macOS: MiniPlayerView (320x120 window) + MenuBarExtra
- iOS: ContentView (full-size)
- Menu bar shows play/pause status + AirPlay connection indicator

### Core Components

**AppState** (`Shared/Models/AppState.swift`)
- Central `@MainActor` observable state
- Orchestrates: MediaPlayerController, AirPlayManager, TranscodeManager
- Persists: device name, compatibility mode, ultra quality setting
- Auto-cleans cache at 80% playback progress

**TranscodeManager** (`Shared/Transcoder/TranscodeManager.swift`)
- Base class with macOS-specific extension
- 4 conversion paths:

| Path | Trigger | Action |
|------|---------|--------|
| 0 | H.264+AAC in MP4/MOV | Direct playback (no conversion) |
| 1 | H.264+AAC in MKV/AVI | Fast remux to MP4 |
| 2 | H.264+DTS/AC3 | Copy video, transcode audio via HLS |
| 3 | XviD/H.265/VP9/etc | Full transcode via HLS |

**MediaAnalyzer** (`Shared/Utils/MediaAnalyzer.swift`)
- Runs ffprobe to analyze video/audio codecs
- Determines which conversion path to use

**LocalHTTPServer** (`Shared/HTTPServer/LocalHTTPServer.swift`)
- Network.framework-based HTTP server
- Serves HLS playlist + .ts segments on ports 8765-8775
- Required because AirPlay needs http:// URLs

**FFmpegProcess** (`macOS/Transcoder/FFmpegProcess.swift`)
- Actor for managing FFmpeg subprocess
- Handles process lifecycle and error output

### UI Components

**MiniPlayerView** (`macOS/Views/MiniPlayerView.swift`)
- Compact 320x120 Winamp-style player
- Shows: file name, progress bar, playback controls, AirPlay button
- Status indicator: green (playing), yellow (paused), orange (converting)

**MenuBarContentView** (in `LiquidCastApp.swift`)
- Menu bar dropdown with playback controls
- Settings: Ultra Quality, Target Device, Clear Cache

### Settings

**Ultra Quality** (`transcodeManager.ultraQualityAudio`)
- OFF: 192kbps stereo AAC, standard video bitrates
- ON: 320kbps 5.1 AAC, higher video bitrates (15-20 Mbps)

**Compatibility Mode** (`appState.compatibilityMode`)
- `.appleTV`: H.264 High profile allowed
- `.smartTV`: H.264 Main profile for wider compatibility

## Project Structure

```
LiquidCast/
├── Shared/
│   ├── LiquidCastApp.swift           # App entry + menu bar
│   ├── Models/
│   │   └── AppState.swift            # Central state
│   ├── Views/
│   │   ├── ContentView.swift         # iOS main view
│   │   ├── AirPlayButtonView.swift
│   │   └── ...
│   ├── Transcoder/
│   │   └── TranscodeManager.swift    # Base transcode class
│   ├── HTTPServer/
│   │   └── LocalHTTPServer.swift     # HLS server
│   ├── MediaPlayer/
│   │   └── MediaPlayerController.swift
│   └── Utils/
│       ├── MediaAnalyzer.swift       # ffprobe wrapper
│       ├── CacheManager.swift
│       └── FormatDetector.swift
├── macOS/
│   ├── Views/
│   │   └── MiniPlayerView.swift      # Mini player UI
│   └── Transcoder/
│       ├── TranscodeManagerMacOS.swift
│       ├── FFmpegProcess.swift
│       └── HLSSegmentMonitor.swift
└── iOS/
    └── Transcoder/
        └── TranscodeManageriOS.swift # Stub (no FFmpeg on iOS)
```

## Key Dependencies

- **FFmpeg** (macOS): `brew install ffmpeg`
  - Searched at: `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`
- No SPM dependencies - Apple frameworks only

## Common Tasks

### Adding a new conversion path
1. Update `MediaAnalyzer.swift` to detect the new format
2. Add handling in `TranscodeManagerMacOS.swift`

### Changing audio/video quality
- Modify `calculateBitrate()` in TranscodeManagerMacOS.swift
- Audio settings in `performHLSTranscode()` around line 208
