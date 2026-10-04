# Streaming architecture

How LiquidCast turns an arbitrary video file into something an Apple TV plays smoothly, and why
each piece is the way it is. Every FFmpeg behaviour described here was verified against FFmpeg 8.

## Pipeline

```
file ─► MediaAnalyzer (ffprobe)
          │
          ├─ H.264 + AAC in MP4/MOV, or (Apple TV) ─► AVPlayer(file URL)       direct play
          │  HEVC hvc1 / AC-3 / E-AC-3 in MP4/MOV
          │
          └─ anything else ─► StreamProfile + SegmentPlan
                                 │
                                 ▼
                             HLSSession ◄── GET /<session>/<n>.ts|m4s ── LocalHTTPServer ◄── Apple TV
                                 │                                        ▲
                                 ▼                                        │
                             FFmpegProcess (one "job" at a time) ──► j<job>_<n>.ts|mp4
```

| Source | Video | Audio |
|---|---|---|
| 8-bit 4:2:0 H.264 (Baseline/Main/High) in MKV/AVI/TS, or with DTS/AC3/... | stream copy (MPEG-TS) | see below |
| HEVC Main/Main 10 (SDR, HDR10, HLG, Dolby Vision 7/8), Apple TV receiver | stream copy (fMP4), HDR kept | see below |
| anything else — or copy would give segments over 10s | H.264 (`h264_videotoolbox`, MPEG-TS); HDR tone-mapped to SDR | see below |

Audio: AC-3 and E-AC-3 (including Dolby Atmos) are copied untouched for an Apple TV receiver.
Everything else becomes AAC in mono, stereo or 5.1 (Ultra keeps 5.1, never upmixes), resampled to
48kHz if higher.

| File | Responsibility |
|---|---|
| `SegmentPlan.swift` | Segment boundaries for the whole movie, decided up front; renders the VOD playlist |
| `StreamProfile.swift` | Encoding choices and the FFmpeg arguments for a job starting at any segment |
| `KeyframeIndex.swift` | Source keyframe times (cached per file); where a seek actually lands |
| `HLSSession.swift` | Produces segments on demand, restarts/pauses FFmpeg, discards a job's pre-roll |
| `FFmpegProcess.swift` | Non-blocking subprocess: kill, SIGSTOP/SIGCONT, kill-all on quit |
| `MP4Segment.swift` | fMP4: shared init segment, media sections, HEVC codec string from `hvcC` |
| `LocalHTTPServer.swift` | HTTP/1.1 off the main thread; async handlers may wait for a segment |

## Why a complete VOD playlist

The playlist lists every segment and ends with `#EXT-X-ENDLIST` before encoding starts. So:

- the player knows the full duration immediately and seeks natively, with no seek-offset math in the app
- playback starts where we say (`#EXT-X-START`, used for resume), not "3 segments from the live edge",
  which is what AVPlayer does with a growing playlist
- a request for a segment that doesn't exist yet waits (HTTP response held open, up to 60s, then 503)

Segments cover the *video* stream's length (`MediaAnalysis.videoEnd`), not the container's:
audio often runs a little longer, and FFmpeg can't cut segments where there's no video.

## Producing segments on demand

`HLSSession.segment(n)`:

1. already written → serve it
2. the running job will reach it within `maxForwardGap` (4) segments → wait
3. otherwise (a seek) → kill the job, start a new one at `n`

Each job writes `j<job>_<n>.ts` (or `.mp4`), so a restart never overwrites a file that may be in flight.
FFmpeg appends a line to the job's CSV segment list only once a segment file is complete;
that's the only "ready" signal used.

Resource bounds:
- **CPU/GPU:** a job more than 40 segments ahead of the latest request is paused (SIGSTOP), and
  resumes within 20.
- **Disk:** only segments from 30 behind to ~46 ahead of the latest request are kept; the rest are
  deleted and regenerated if requested again. That's about 75 segments: ~0.5GB at 8 Mbps, ~1GB at 15.

Failures:
- a job that fails (or can't be probed/launched) fails the requests it was serving; the player's
  retry restarts a job
- after 3 failures without output *at the same start segment*, requests there get a 500. Other
  positions in the movie still work
- a job that exits cleanly before the plan's end marks the rest as not found (404) instead of
  restarting there forever
- a HEAD request never starts FFmpeg; a client that disconnects releases its waiting request

## Passthrough for Apple TV (HEVC/HDR, Dolby audio, native files)

For an Apple TV receiver ("passthrough allowed"), whatever it decodes natively isn't converted:

- **Native files** — an MP4/MOV with H.264 or HEVC (`hvc1`, no Dolby Vision) and AAC/AC-3/E-AC-3 is
  played directly from the file; FFmpeg doesn't run at all.
- **Dolby audio** — AC-3/E-AC-3 is stream-copied into the segments (MPEG-TS or fMP4), so 5.1 and
  Atmos reach the TV intact. Copied audio also lines up exactly across restarts: same source frames,
  no AAC priming. HEVC (fMP4) streams declare it in the multivariant playlist (`ac-3`/`ec-3`); H.264
  (MPEG-TS) streams are served as a media playlist and the receiver identifies the codec from the
  stream.
- **Audio track choice** — the default audio track is streamed. With Dolby passthrough, a
  same-language AC-3/E-AC-3 track wins over a default TrueHD/DTS one (a common MKV layout), since
  it can be passed through instead of converted.
- **HEVC/HDR video** — below.

### HEVC and HDR

Apple's HLS spec requires fragmented MP4 for HEVC, so HEVC passthrough streams differ from the
MPEG-TS ones in three ways (everything else, including restarts, is shared):

- **Segments.** FFmpeg's segment muxer writes each segment as a self-contained fragmented MP4
  (`ftyp` `moov` `moof`/`mdat`…) with `movflags=+frag_keyframe+delay_moov+default_base_moof+frag_discont`
  and `use_editlist=1`. `delay_moov` (not `empty_moov`) because the muxer must see copied AC-3/E-AC-3
  packets before it can write the `moov`. `frag_discont` + `use_editlist=1` make decode times (`tfdt`)
  absolute instead of restarting at 0 in every file, but anchor each *file* at its first frame's
  presentation time: with B-frames, decode times are shifted by that frame's composition offset
  (it differs per file), and a per-file edit list (`edts`) undoes it. So `MP4Segment` normalises
  what's served:
  - **init** (`init.mp4`, `#EXT-X-MAP`): any file's `ftyp`+`moov` with `edts` removed. Byte-identical
    for every file of every job
  - **media segment** (`<n>.m4s`): the `moof`/`mdat` boxes, each track's `tfdt` reduced by that file's
    first composition offset, which puts every file on the true decode timeline

  Serving one file's raw init with everyone's segments instead puts video up to a few frames
  (~0.1–0.2s) off audio, depending on which file the init came from; `use_editlist=0` and
  `negative_cts_offsets` don't fix it (decode times reset to 0 / video consistently late).
- **Multivariant playlist.** `playlist.m3u8` declares the variant (`HLSVariant`), so the receiver
  knows the codec and dynamic range before downloading: `CODECS` (exact HEVC string, read from the
  `hvcC` box of a one-frame probe), `VIDEO-RANGE` (PQ/HLG/SDR), `RESOLUTION`, bandwidth (file average,
  peak at 2×, Apple's VOD allowance) and `FRAME-RATE`. AVFoundation rejects an HEVC PQ variant without
  `FRAME-RATE` ("unsupported URL"). The media playlist is `media.m3u8`.
- **Dolby Vision.** Profiles 7 (UHD Blu-ray) and 8 have an HDR10-compatible base layer: the DV
  metadata and enhancement layer are stripped (`dovi_rpu=strip=1`) and it plays as HDR10. Profile 5
  has no such base layer and isn't passed through.

Whether the receiver allows passthrough: `CompatibilityMode` is detected from the AirPlay device name.
Brand names (Samsung, LG, Sony, Vizio, …) mean a smart TV, which gets converted streams; anything
else, including tvOS's default room names ("Living Room"), is taken as an Apple TV. The user can
override the mode in the menu.

Passthrough is a set of capabilities (`Passthrough`: HEVC/HDR, Dolby audio, direct file playback).
If passed-through playback fails, `AppState` retries without the most likely culprit, from the same
position: HEVC first (e.g. an Apple TV HD), then direct file playback, then Dolby audio (which every
Apple TV decodes). Another failure drops the next one. Only a decode/format error on the receiver
(not a network drop or server error) records that capability as unsupported *for that device*, so an
Apple TV HD that fails HEVC keeps Dolby passthrough. "Retry HDR & Dolby Passthrough on All Devices" in
the menu clears the records.

HDR sources that are re-encoded (non-HEVC, or a receiver without HEVC) are tone-mapped to SDR:
`zscale` to linear light, `tonemap=hable`, `zscale` to BT.709, tagged BT.709. Input primaries are
stated as BT.2020 (files often leave them untagged, and zscale then fails). It's software: ~6×
realtime at 1080p; 4K sources are scaled to 1080p first (in the same zscale pass), which brings them
from ~1.4× to ~3.5× realtime and cuts CPU by two thirds.

## Making restarted jobs interchangeable

A segment written by a job that started at segment 40 must match the one a job started at 0
would have written: same boundary, same timestamps. Otherwise playback crossing from one job's
segments into another's would jump. The mechanisms:

- **Pinned timeline.** `-output_ts_offset = 10 + seek` makes output time = media time + 10s
  (media time = source pts − container start). The +10s keeps B-frame DTS positive at 0, so FFmpeg
  never shifts one job's timestamps differently from another's.
- **Exact frame times.** `-fps_mode passthrough` (the segment muxer would otherwise default to CFR,
  re-gridding frames from each job's start) and `-enc_time_base 1:90000` (the default 1/framerate
  snaps frame times to a grid that starts at the seek point).
- **Pre-roll.** A restart seeks 0.5s before its boundary. The pre-roll goes into a throwaway file
  numbered `n-1`, which the session deletes. So the boundary is cut inside the stream by the same
  rule as in a continuous run, and audio lands in the same segment either way.
- **Explicit cut points.** `-segment_times` is measured from the first *video* packet the muxer
  receives (`reference_stream_first_pts` in `libavformat/segment.c`):
  - re-encode: keyframes are forced at every boundary (list form of `-force_key_frames`, compared
    against output time; the `expr:` form measures `t` from the job's first frame, so it differs
    between jobs) and nowhere else (`-g 9999`). So a 0.25s cut window is safe.
  - copy: the demuxer lands on an *indexed* keyframe, which may be well before the seek (MKV cues
    don't list every keyframe). Cuts are measured from that landing point.
- **Landing probe.** For both modes, `KeyframeIndex.seekLanding` runs the identical FFmpeg seek and
  reports the first packet (~50ms). The demuxer can also land *after* the seek (MPEG-TS seeks forward
  to the next keyframe), which would skip the boundary, so the session backs the seek off
  (2s, 4s, 8s, …) until it lands before the boundary.
- **Boundary epsilon.** Keyframe times sit 0.1234ms before boundaries, off the 1ms (MKV), 1/90000
  (TS) and common MP4 timestamp grids, so a frame exactly on a boundary can't fall either side
  through float rounding.

## Things that were wrong before, and must not come back

- `waitUntilExit()` inside the `FFmpegProcess` actor blocked the actor, so kill/cancel waited for
  FFmpeg to transcode the whole movie. Stale FFmpegs then wrote into the same folder as their
  replacements, interleaving two timelines (jumping playback).
- A growing playlist without a type is "live" to AVPlayer: it started near the live edge and
  reported an indefinite duration, so progress and resume never worked.
- FFmpeg's default VideoToolbox GOP is 12 frames (a keyframe every 0.5s), wasting much of the bitrate.
- Default stream mapping picks up text subtitles, which can't go into MPEG-TS, and the job fails.
- Cover art is exposed as a video stream and was sometimes picked as "the movie".
- Reading a child's stdout only after it exits deadlocks above 64KB, and waiting for pipe EOF hangs
  if another child inherited the pipe. `ProcessRunner` writes to a temp file instead.
- FFmpeg children survive the app quitting unless killed (`FFmpegProcess.killAll()`).
- App Nap throttled the server and FFmpeg when the window was hidden.

## Known limits

- **Re-encode junctions may be one frame off for some sources.** With MPEG-TS sources whose video
  starts after the container start, FFmpeg offsets frame times differently with and without a seek.
  A frame on a boundary can then land in a different segment in two jobs. That only matters when
  playback runs continuously from one job's segments into another's (after seeking back into an
  earlier job's range), and the shared timeline keeps it to one frame. Never a jump.
- **AAC frame phase.** Each job's audio encoder starts its own 1024-sample frame grid, so at a job
  junction audio can overlap or gap by up to ~21ms.
- **Copy needs a keyframe scan.** The first play of a stream-copied file demuxes it once to find
  keyframes (~0.7s per 1.7GB from SSD; slow from network shares). The result is cached.
- **Re-encoding is always H.264.** Non-HEVC HDR sources (e.g. VP9/AV1 HDR) are tone-mapped to SDR
  rather than re-encoded as HEVC HDR.
- **Passthrough detection is optimistic.** Non-brand device names are taken as Apple TVs with
  HEVC/HDR support; an older receiver fails once, then falls back (see above). A failure that only
  shows as a stall, without the player reporting an error, doesn't trigger the fallback.
- **Dolby Vision profile 5** (no HDR10 base layer) is re-encoded without proper DV colour
  conversion, so colours are wrong. Needs libplacebo-style DV processing.
- **Tone-mapped output is at most 1080p** (4K HDR is scaled down for SDR receivers to keep software
  tone mapping fast).
- **Untested on hardware here.** HEVC/HDR passthrough was verified with AVPlayer on a Mac (HDR display),
  not yet on an Apple TV over AirPlay.
- **Open GOP.** Some files flag non-IDR keyframes (open-GOP H.264 I-frames, HEVC CRA pictures);
  a segment starting there drops a few leading frames after a seek. Not detected yet.
- DTS and TrueHD are converted to AAC (up to 5.1), not to a Dolby format, so DTS:X/TrueHD Atmos
  lose their object audio.
- Only the first audio track is used; subtitles are dropped.
- The stream URL contains the Mac's IP address at the time playback started. A network change
  mid-playback (VPN, Wi-Fi ↔ Ethernet) breaks the stream.

## Verifying changes

There's no test target yet. Changes to this pipeline were verified with a harness that compiles
the real sources and checks, for re-encode and stream-copy sources in MKV and MPEG-TS:

- for every restart point, the restarted job's segment `n` starts at the same video timestamp
  (copy: exact; re-encode: within one frame) and audio within 50ms of a continuous job's
- a real AVPlayer over HTTP: starts at the resume point, knows the full duration, survives far
  seeks (resuming in under 1.5s), leaves exactly one FFmpeg running, gets paused when far ahead,
  keeps disk use bounded, and cleans up on stop
- edge cases: a re-encoded file shorter than one segment, video shorter than audio
- HEVC/HDR: codec string from `hvcC`; fMP4 restarts share one init and match a continuous job's
  decode times; an HDR10 file streams through the multivariant playlist, AVFoundation sees a PQ
  variant, it plays from the resume point and after a far seek, the video track stays `hvc1`; without
  HEVC support the same file becomes tone-mapped BT.709 H.264 and plays
- fMP4 timing: with a B-frame HEVC source, served segments (restarted or not) have their first video
  frame at its source time and audio alongside — the check that catches lip-sync offsets
- audio track choice: a DTS-first MKV passes its E-AC-3 track through, and converts the DTS one without
  passthrough
- Dolby audio: copied AC-3 (MPEG-TS) and E-AC-3 (fMP4) restarts match a continuous job exactly;
  AVPlayer plays both with `ac-3`/`ec-3` tracks, before and after a far seek; an H.264 + E-AC-3 MP4
  is played directly with passthrough and converted to HLS without
