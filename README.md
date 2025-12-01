# LiquidCast

A native macOS + iOS app for high-quality media casting to Apple TV.

## Features

### Two Quality Modes

1. **Highest Quality** - Direct streaming via AVPlayer with `allowsExternalPlayback = true`
   - No re-encoding, best quality
   - Perfect for local video files

2. **High Quality** (macOS only) - ScreenCaptureKit + VideoToolbox H.265 encoding
   - Capture any window or app
   - 50 Mbps H.265 encoding at 60fps

### Liquid Glass UI
- Beautiful frosted glass UI using SwiftUI's `.ultraThinMaterial`
- Subtle gradients and animations
- Dark mode optimized

## Requirements

- **macOS**: 13.0+ (Ventura)
- **iOS**: 16.0+
- **Xcode**: 15.0+

## Project Structure

```
LiquidCast/
├── Shared/                    # Cross-platform code (95%)
│   ├── Views/                 # SwiftUI views
│   │   ├── ContentView.swift
│   │   ├── LiquidGlassCard.swift
│   │   ├── ModeSwitcher.swift
│   │   └── AirPlayButtonView.swift
│   ├── MediaPlayer/          # AVPlayer wrapper
│   │   └── MediaPlayerController.swift
│   ├── AirPlayManager/       # AirPlay device management
│   │   └── AirPlayManager.swift
│   └── Models/
│       └── AppState.swift
├── macOS/
│   ├── ScreenCapture/        # ScreenCaptureKit integration
│   │   └── ScreenCaptureManager.swift
│   └── WindowPicker/         # Google Meet-style window picker
│       └── WindowPickerView.swift
├── iOS/
│   └── DocumentPicker/       # Files app integration
│       └── DocumentPickerView.swift
└── Resources/
    └── Assets.xcassets/
```

## Building

1. Open `LiquidCast.xcodeproj` in Xcode 15+
2. Select target:
   - `LiquidCast (macOS)` for Mac
   - `LiquidCast (iOS)` for iPhone/iPad
3. Build and run (Cmd+R)

### macOS Screen Recording Permission

For window capture mode, grant Screen Recording permission:
System Preferences → Privacy & Security → Screen Recording → Enable LiquidCast

## Key Technologies

- **AVFoundation** - Media playback with AirPlay
- **AVRoutePickerView** - System AirPlay device picker
- **ScreenCaptureKit** - Window/screen capture (macOS)
- **VideoToolbox** - Hardware H.265 encoding

## Video Encoding Settings

```swift
// H.265 settings for maximum quality
kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel
kVTCompressionPropertyKey_AverageBitRate: 50_000_000  // 50 Mbps
kVTCompressionPropertyKey_Quality: 1.0
```

## License

Private project.
