# Streaming architecture

How LiquidCast turns an arbitrary video file into something an Apple TV plays smoothly, and why
each piece is the way it is. Every FFmpeg behaviour described here was verified against FFmpeg 8.

## Pipeline

```
file ─► MediaAnalyzer (ffprobe)
          │
          ├─ H.264 + AAC in MP4/MOV ─────────────► AVPlayer(file URL)          direct play
          │
          └─ anything else ─► StreamProfile + SegmentPlan
                                 │
                                 ▼
                             HLSSession ◄── GET /<session>/<n>.ts ── LocalHTTPServer ◄── Apple TV
                                 │                                        ▲
                                 ▼                                        │
                             FFmpegProcess (one "job" at a time) ──► j<job>_<n>.ts
```

| Source | Video | Audio |
|---|---|---|
| 8-bit 4:2:0 H.264 (Baseline/Main/High) in MKV/AVI/TS, or with DTS/AC3/... | stream copy | AAC |
| HEVC, 10-bit, 4:2:2/4:4:4, XviD, VP9, ... — or copy would give segments over 10s | H.264 (`h264_videotoolbox`) | AAC |

Audio is AAC in mono, stereo or 5.1 (Ultra keeps 5.1, never upmixes), resampled to 48kHz if higher.

| File | Responsibility |
|---|---|
| `SegmentPlan.swift` | Segment boundaries for the whole movie, decided up front; renders the VOD playlist |
| `StreamProfile.swift` | Encoding choices and the FFmpeg arguments for a job starting at any segment |
| `KeyframeIndex.swift` | Source keyframe times (cached per file); where a seek actually lands |
| `HLSSession.swift` | Produces segments on demand, restarts/pauses FFmpeg, discards a job's pre-roll |
| `FFmpegProcess.swift` | Non-blocking subprocess: kill, SIGSTOP/SIGCONT, kill-all on quit |
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

Each job writes `j<job>_<n>.ts`, so a restart never overwrites a file that may be in flight.
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
- **H.264 output only.** Apple's HLS spec requires fMP4 segments for HEVC, so HEVC output (smaller,
  better for 4K) needs fMP4 with `#EXT-X-MAP` first.
- **HDR is not tone-mapped.** 10-bit HDR sources are re-encoded to 8-bit H.264 without converting
  PQ/HLG, so they look washed out. Fix together with fMP4/HEVC output (HDR10/HLG passthrough to
  Apple TV 4K, tone mapping only for SDR receivers).
- **Open-GOP H.264.** Some MKVs flag non-IDR I-frames as keyframes; cutting there can show brief
  artifacts after a seek. Not detected yet.
- AC-3/E-AC-3 is re-encoded to AAC even though Apple TV plays it natively.
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
