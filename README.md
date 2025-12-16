# LiquidCast

**Cast any video to Apple TV in 4K with 5.1 surround sound.**

A compact macOS app that plays MKV, AVI, and other formats on your Apple TV via AirPlay — with quality you can't tell from the original.

<img width="612" height="324" alt="Screenshot 2025-12-15 at 11 22 13 PM" src="https://github.com/user-attachments/assets/862d798b-ce8e-4a25-b766-9fe8aa85112d" />

## Why LiquidCast?

Apple TV only plays certain formats (MP4, MOV). Got an MKV with 5.1 audio? AVI from years ago? LiquidCast handles it:

- **Any format plays** — MKV, AVI, WebM, MP4, MOV, whatever
- **Original quality** — 4K video + 5.1 surround audio preserved
- **Instant start** — Playback begins in seconds, not minutes
- **Tiny footprint** — Winamp-style 320×120 mini player

## How It Works

LiquidCast automatically picks the fastest path to play your video:

| Your File | What Happens | Wait Time |
|-----------|--------------|-----------|
| MP4/MOV (H.264 + AAC) | Plays directly | None |
| MKV (H.264 + AAC) | Quick repackage | ~2 sec |
| MKV (H.264 + DTS/5.1) | Audio converted, video untouched | ~3 sec |
| AVI/other formats | Full transcode via streaming | ~5 sec |

Videos stream while converting — no waiting for the whole file.

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

## Settings

Access from the menu bar:

- **Ultra Quality** — Maximum bitrates, 5.1 surround preserved
- **Target Device** — Apple TV (best) or Smart TV (compatible)
- **Clear Cache** — Delete converted files

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

## Under the Hood

- **HLS Streaming** — Start watching while the file converts
- **Hardware encoding** — Uses your Mac's VideoToolbox for speed
- **Local server** — Streams to Apple TV over your network
- **Minimal dependencies** — Just FFmpeg + Apple frameworks

## License

Private project.
