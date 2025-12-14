# LiquidCast

A compact macOS app for casting **any video format** to Apple TV via AirPlay.

![Mini Player](docs/mini-player.png)

## Features

- **Play any video format** - MKV, AVI, MP4, MOV, WebM, etc.
- **Smart transcoding** - Automatically converts incompatible formats via FFmpeg
- **Compact mini player** - Winamp-style 320x120 window
- **Menu bar integration** - Control playback from the menu bar
- **Ultra Quality mode** - 320kbps 5.1 surround audio + higher video bitrates

## How It Works

LiquidCast uses FFmpeg to convert videos for AirPlay compatibility:

| Your File | What Happens | Speed |
|-----------|--------------|-------|
| MP4 (H.264 + AAC) | Direct playback | Instant |
| MKV (H.264 + AAC) | Quick remux to MP4 | ~2 seconds |
| MKV (H.264 + DTS/AC3) | Audio transcode, video copy | Fast |
| AVI (XviD/etc) | Full transcode via HLS | Starts in ~5s |

For files needing transcode, playback starts immediately via HLS streaming while conversion continues in background.

## Requirements

- **macOS 13.0+** (Ventura or later)
- **FFmpeg** - Install with Homebrew:
  ```bash
  brew install ffmpeg
  ```

## Installation

1. Clone or download this repo
2. Open `LiquidCast.xcodeproj` in Xcode 15+
3. Build and run (Cmd+R)

## Usage

1. **Connect to AirPlay** - Click the AirPlay icon and select your Apple TV
2. **Open a video** - Click + or drag a file onto the mini player
3. **Control playback** - Use the mini player or menu bar

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Space | Play/Pause |
| ← | Skip back 10s |
| → | Skip forward 30s |
| ⌘O | Open file |
| ⌘Q | Quit |

## Settings (Menu Bar)

- **Ultra Quality** - Higher bitrates + 5.1 surround audio
- **Target Device** - Apple TV (best quality) or Smart TV (wider compatibility)
- **Clear Cache** - Remove converted files

## Project Structure

```
LiquidCast/
├── Shared/
│   ├── LiquidCastApp.swift      # App entry + menu bar
│   ├── Models/AppState.swift    # Central state
│   ├── Transcoder/              # FFmpeg integration
│   ├── HTTPServer/              # HLS streaming server
│   └── Utils/                   # MediaAnalyzer, CacheManager
├── macOS/
│   ├── Views/MiniPlayerView.swift
│   └── Transcoder/              # FFmpeg process management
└── iOS/                         # iOS support (limited)
```

## Technical Details

- **HLS Streaming** - Converts to HTTP Live Streaming for immediate playback
- **Hardware Encoding** - Uses VideoToolbox H.264 encoder
- **Local HTTP Server** - Serves HLS segments to AirPlay (port 8765-8775)
- **No external dependencies** - Uses only Apple frameworks + FFmpeg

## License

Private project.
