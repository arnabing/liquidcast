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
- macOS: MiniPlayerView (500x180 window) + MenuBarExtra
- iOS: ContentView (full-size)
- Menu bar shows play/pause status + AirPlay connection indicator

### Core Components

**AppState** (`Shared/Models/AppState.swift`)
- Central `@MainActor` observable state
- Orchestrates: MediaPlayerController, AirPlayManager, TranscodeManager
- Persists: device name, compatibility mode, ultra quality setting
- Saves playback position every 5s and resumes from it (cleared past 95%); seeks go straight to AVPlayer
- `startOver()`: forget the saved position and reload from 0:00 ("Start Over" in the player and menu); a resumed file's start offset is in the playlist (EXT-X-START), so a receiver loading it lands there
- Subtitle menu (text renditions via media selection; bitmap tracks via burn-in reload), follows network address changes (`NWPathMonitor`), stall check for passthrough

**TranscodeManager** (`Shared/Transcoder/TranscodeManager.swift` + `macOS/Transcoder/TranscodeManagerMacOS.swift`)
- `prepareForAirPlay` returns the file URL (direct play: H.264+AAC in MP4/MOV; for Apple TV also HEVC hvc1 and Dolby audio) or an http:// HLS playlist
- Owns the active `HLSSession` and the `LocalHTTPServer` (started once, kept for the app's lifetime)

**On-demand HLS** (`macOS/Transcoder/`) - read `docs/STREAMING.md` before changing anything here
- `SegmentPlan`: all segment boundaries decided up front → complete VOD playlist (full duration, native seeking, resume via `EXT-X-START`)
- `StreamProfile`: copy (8-bit H.264 → MPEG-TS; HEVC/HDR → fMP4 for Apple TV) or re-encode (VideoToolbox H.264, HDR tone-mapped); audio AAC, or AC-3/E-AC-3 copied for Apple TV; FFmpeg args for a job starting at any segment
- `MP4Segment`: fMP4 init (edit lists removed) and media sections (decode times rebased per file), HEVC codec string; `HLSVariant` (in `SegmentPlan.swift`) renders the multivariant playlist (CODECS, VIDEO-RANGE, FRAME-RATE)
- `Passthrough` (in `TranscodeManager.swift`): what an Apple TV gets untouched (HEVC/HDR, Dolby audio, native files); `AppState` drops one capability per failure and remembers decode failures per device
- `HLSSession`: serve finished segment / wait for the running job / restart FFmpeg at the requested segment; pauses FFmpeg when far ahead; adaptive bitrate for re-encoded streams; serves WebVTT subtitle segments
- `KeyframeIndex`: keyframe scan for stream copy (cached), and where an FFmpeg seek actually lands
- `Subtitles.swift` (`WebVTT`): text subtitles → segmented WebVTT renditions (identity X-TIMESTAMP-MAP); bitmap subtitles are burned in via `StreamProfile.burnInSubtitleIndex`
- `FFmpegProcess`: actor around the subprocess; never blocks (no `waitUntilExit`), SIGKILL/SIGSTOP, `killAll()` on quit
- Restarted jobs must produce segments identical to a continuous run (timestamps pinned to media time, pre-roll discarded, explicit cut points). The invariants are subtle and each one fixed a real bug.

**MediaAnalyzer** (`Shared/Utils/MediaAnalyzer.swift`)
- Runs ffprobe (via `ProcessRunner`) to analyze codecs, duration, container start time
- Ignores cover-art "video" streams

**LocalHTTPServer** (`Shared/HTTPServer/LocalHTTPServer.swift`)
- Network.framework HTTP/1.1, off the main thread, async request handlers (a segment request can wait)
- Routes per session: `playlist.m3u8` (multivariant), `media.m3u8`, `init.mp4`, `<n>.ts` / `<n>.m4s`, `subs/<stream>/index.m3u8`, `subs/<stream>/<n>.vtt`; ports 8765-8775, 9876-9885
- Reports per-response send time (`onDelivered`), used for adaptive bitrate
- Required because AirPlay needs http:// URLs reachable from the receiver

### UI Components

**MiniPlayerView** (`macOS/Views/MiniPlayerView.swift`)
- Compact 500x180 Winamp-style player
- Shows: file name, progress bar, playback controls, AirPlay button
- Status indicator: green (playing), yellow (paused), orange (preparing)

**MenuBarContentView** (in `LiquidCastApp.swift`)
- Menu bar dropdown with playback controls and Subtitles menu
- Settings: Ultra Quality, Target Device, Clear Cache, Retry HDR & Dolby Passthrough

### Settings

**Ultra Quality** (`transcodeManager.ultraQualityAudio`)
- OFF: 192kbps stereo AAC, standard video bitrates (8 Mbps 1080p)
- ON: 320kbps AAC keeping up to 5.1 (never upmixed), higher video bitrates (15 Mbps 1080p, 20 Mbps 4K)
- Video peaks are capped at 1.5x the target (`-maxrate`) so Wi-Fi delivery doesn't stall

**Compatibility Mode** (`appState.compatibilityMode`)
- `.appleTV`: H.264 High profile; passthrough of HEVC/HDR, AC-3/E-AC-3 (Atmos) and Apple-native files (falls back to converting, per device, if it fails)
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
│       ├── TranscodeManagerMacOS.swift  # analyze → direct play or HLS session
│       ├── HLSSession.swift          # on-demand segment production
│       ├── SegmentPlan.swift         # boundaries + VOD playlist
│       ├── StreamProfile.swift       # FFmpeg arguments per job
│       ├── KeyframeIndex.swift       # keyframe scan, seek landing probe
│       ├── MP4Segment.swift          # fMP4 init/media sections, codec strings
│       ├── Subtitles.swift           # WebVTT extraction and segmenting
│       └── FFmpegProcess.swift       # subprocess actor
└── iOS/
    └── Transcoder/
        └── TranscodeManageriOS.swift # Stub (no FFmpeg on iOS)
```

## Key Dependencies

- **FFmpeg** (macOS): `brew install ffmpeg`
  - Searched at: `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`
- No SPM dependencies - Apple frameworks only

## Common Tasks

### Changing what gets copied vs re-encoded
- `MediaAnalysis.conversionPath` (`MediaAnalyzer.swift`) decides; `StreamProfile.make` maps it to copy/encode

### Changing audio/video quality
- `StreamProfile.bitrateKbps` and `StreamProfile.make`

### Verifying streaming changes
- Re-run the restart-alignment and AVPlayer checks described at the end of `docs/STREAMING.md`
