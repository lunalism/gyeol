# M1 Asset Timescale Probe

## Summary of findings

1. **`AVAssetWriter` with no `mediaTimeScale` quantizes every track to the
   QuickTime default 600.** PTS written as exact `1001/24000` came back as
   `25/600` (= 1/24, not 1001/24000); total duration is preserved (3003/600)
   by uneven per-frame durations. This is a property of the writer default,
   not of the container: setting `AVAssetWriterInput.mediaTimeScale` (and
   `movieTimeScale`) to the rate's denominator produces exact PTS
   (`1001/24000`) and `naturalTimeScale` equal to the requested value.
   **Consequence for Gyeol's own export: the writer timescale must be set
   explicitly — the default silently destroys NTSC exactness.**
2. **Round trip 120000 → 600 → 120000 is NOT identity for NTSC rates**
   (5005 → 5000; 500500 → 500600). Residual is bounded by half a 600-tick
   = 100 ticks@120000 = 0.02–0.05 frames depending on rate — it does not
   accumulate, and never approaches the 1/4-frame threshold in §5.6.1.
   The threshold is therefore not contradicted by measurement; the measured
   worst case is 0.05 frame, an order of magnitude under it.
3. **Round trip through the exact denominators (24000/30000/60000/24/…) is
   identity for every boundary tested** — every one of them divides 120000.
4. **`AVPlayer.currentTime()` is on the 1_000_000_000 (host nanosecond)
   timescale during and after playback — never the asset timescale.** The
   only APIs that speak the asset's timescale are the reader PTS, the
   video-output display timestamps, `minFrameDuration`, and `duration`.
   The adapter must not assume player time arrives at a media timescale.
5. **Real user media was not measured** — no camera/screen-recording files
   exist on this machine (directories were readable; simply no footage).
   Real cameras commonly use 600/2500/30000/90000-class timescales; rerun
   the probe when real footage is available, especially for finding 2.


Measured on Version 26.5.2 (Build 25F84), Mac14,15. Generated clips: H.264 640×360, ~5 s, PTS written at N × exact frame duration (e.g. 1001/24000). Round-trip conversion uses `CMTimeConvertScale` with `.default` rounding (half away from zero).

Reading notes:

- Reader PTS come from `AVAssetReaderTrackOutput` with `outputSettings: nil`
  (no decode), so samples arrive in DECODE order — H.264 B-frames make the
  PTS non-monotonic. That is expected, not a defect.
- "paused, before play" reads `0/1` — the `CMTime.zero` constant, not a
  measurement.
- Two generated sets: **default** leaves `AVAssetWriterInput.mediaTimeScale`
  unset; **explicit** pins it (and `movieTimeScale`) to the rate's exact
  denominator (24000, 30000, …).

## Generated clips

## Generated clips — writer default mediaTimeScale

### generated 23.976 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 23.976025 |
| minFrameDuration | 25/600 |
| asset duration | 3003/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 25/600, 50/600, 75/600 |
| reader PTS (first 10) | 0/600, 0/600, 100/600, 50/600, 25/600, 75/600, 200/600, 150/600, 125/600, 175/600 |

Boundary round trip 120000 → 600 → 120000 (d = 5005 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 5005 | 25/600 | 5000 | -5 | -0.000999 |
| 2 | 10010 | 50/600 | 10000 | -10 | -0.001998 |
| 100 | 500500 | 2503/600 | 500600 | 100 | 0.019980 |
| 1000 | 5005000 | 25025/600 | 5005000 | 0 | 0.000000 |

### generated 24 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 24.0 |
| minFrameDuration | 25/600 |
| asset duration | 3000/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 25/600, 50/600, 75/600 |
| reader PTS (first 10) | 0/600, 0/600, 100/600, 50/600, 25/600, 75/600, 200/600, 150/600, 125/600, 175/600 |

Boundary round trip 120000 → 600 → 120000 (d = 5000 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 5000 | 25/600 | 5000 | 0 | 0.000000 |
| 2 | 10000 | 50/600 | 10000 | 0 | 0.000000 |
| 100 | 500000 | 2500/600 | 500000 | 0 | 0.000000 |
| 1000 | 5000000 | 25000/600 | 5000000 | 0 | 0.000000 |

### generated 25 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 25.0 |
| minFrameDuration | 24/600 |
| asset duration | 3000/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 24/600, 48/600, 72/600 |
| reader PTS (first 10) | 0/600, 0/600, 96/600, 48/600, 24/600, 72/600, 192/600, 144/600, 120/600, 168/600 |

Boundary round trip 120000 → 600 → 120000 (d = 4800 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 4800 | 24/600 | 4800 | 0 | 0.000000 |
| 2 | 9600 | 48/600 | 9600 | 0 | 0.000000 |
| 100 | 480000 | 2400/600 | 480000 | 0 | 0.000000 |
| 1000 | 4800000 | 24000/600 | 4800000 | 0 | 0.000000 |

### generated 29.97 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 29.97003 |
| minFrameDuration | 20/600 |
| asset duration | 3003/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 20/600, 60/600, 80/600 |
| reader PTS (first 10) | 0/600, 0/600, 80/600, 40/600, 20/600, 60/600, 160/600, 120/600, 100/600, 140/600 |

Boundary round trip 120000 → 600 → 120000 (d = 4004 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 4004 | 20/600 | 4000 | -4 | -0.000999 |
| 2 | 8008 | 40/600 | 8000 | -8 | -0.001998 |
| 100 | 400400 | 2002/600 | 400400 | 0 | 0.000000 |
| 1000 | 4004000 | 20020/600 | 4004000 | 0 | 0.000000 |

### generated 30 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 30.0 |
| minFrameDuration | 20/600 |
| asset duration | 3000/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 40/600, 60/600, 80/600 |
| reader PTS (first 10) | 0/600, 0/600, 80/600, 40/600, 20/600, 60/600, 160/600, 120/600, 100/600, 140/600 |

Boundary round trip 120000 → 600 → 120000 (d = 4000 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 4000 | 20/600 | 4000 | 0 | 0.000000 |
| 2 | 8000 | 40/600 | 8000 | 0 | 0.000000 |
| 100 | 400000 | 2000/600 | 400000 | 0 | 0.000000 |
| 1000 | 4000000 | 20000/600 | 4000000 | 0 | 0.000000 |

### generated 50 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 50.0 |
| minFrameDuration | 12/600 |
| asset duration | 3000/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 12/600, 36/600, 60/600 |
| reader PTS (first 10) | 0/600, 0/600, 48/600, 24/600, 12/600, 36/600, 96/600, 72/600, 60/600, 84/600 |

Boundary round trip 120000 → 600 → 120000 (d = 2400 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 2400 | 12/600 | 2400 | 0 | 0.000000 |
| 2 | 4800 | 24/600 | 4800 | 0 | 0.000000 |
| 100 | 240000 | 1200/600 | 240000 | 0 | 0.000000 |
| 1000 | 2400000 | 12000/600 | 2400000 | 0 | 0.000000 |

### generated 59.94 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 59.94006 |
| minFrameDuration | 10/600 |
| asset duration | 3003/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 10/600, 30/600, 60/600 |
| reader PTS (first 10) | 0/600, 0/600, 40/600, 20/600, 10/600, 30/600, 80/600, 60/600, 50/600, 70/600 |

Boundary round trip 120000 → 600 → 120000 (d = 2002 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 2002 | 10/600 | 2000 | -2 | -0.000999 |
| 2 | 4004 | 20/600 | 4000 | -4 | -0.001998 |
| 100 | 200200 | 1001/600 | 200200 | 0 | 0.000000 |
| 1000 | 2002000 | 10010/600 | 2002000 | 0 | 0.000000 |

### generated 60 fps (default timescale)

| metric | value |
|---|---|
| naturalTimeScale | 600 |
| nominalFrameRate | 60.0 |
| minFrameDuration | 10/600 |
| asset duration | 3000/600 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/600, 30/600, 50/600, 80/600 |
| reader PTS (first 10) | 0/600, 0/600, 40/600, 20/600, 10/600, 30/600, 80/600, 60/600, 50/600, 70/600 |

Boundary round trip 120000 → 600 → 120000 (d = 2000 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/600 | 0 | 0 | 0.000000 |
| 1 | 2000 | 10/600 | 2000 | 0 | 0.000000 |
| 2 | 4000 | 20/600 | 4000 | 0 | 0.000000 |
| 100 | 200000 | 1000/600 | 200000 | 0 | 0.000000 |
| 1000 | 2000000 | 10000/600 | 2000000 | 0 | 0.000000 |


## Generated clips — explicit mediaTimeScale

### generated 23.976 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 24000 |
| nominalFrameRate | 23.976025 |
| minFrameDuration | 1001/24000 |
| asset duration | 120120/24000 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/24000, 1001/24000, 2002/24000, 3003/24000 |
| reader PTS (first 10) | 0/24000, 0/24000, 4004/24000, 2002/24000, 1001/24000, 3003/24000, 8008/24000, 6006/24000, 5005/24000, 7007/24000 |

Boundary round trip 120000 → 24000 → 120000 (d = 5005 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/24000 | 0 | 0 | 0.000000 |
| 1 | 5005 | 1001/24000 | 5005 | 0 | 0.000000 |
| 2 | 10010 | 2002/24000 | 10010 | 0 | 0.000000 |
| 100 | 500500 | 100100/24000 | 500500 | 0 | 0.000000 |
| 1000 | 5005000 | 1001000/24000 | 5005000 | 0 | 0.000000 |

### generated 24 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 24 |
| nominalFrameRate | 24.0 |
| minFrameDuration | 1/24 |
| asset duration | 120/24 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/24, 1/24, 2/24, 3/24 |
| reader PTS (first 10) | 0/24, 0/24, 4/24, 2/24, 1/24, 3/24, 8/24, 6/24, 5/24, 7/24 |

Boundary round trip 120000 → 24 → 120000 (d = 5000 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/24 | 0 | 0 | 0.000000 |
| 1 | 5000 | 1/24 | 5000 | 0 | 0.000000 |
| 2 | 10000 | 2/24 | 10000 | 0 | 0.000000 |
| 100 | 500000 | 100/24 | 500000 | 0 | 0.000000 |
| 1000 | 5000000 | 1000/24 | 5000000 | 0 | 0.000000 |

### generated 25 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 25 |
| nominalFrameRate | 25.0 |
| minFrameDuration | 1/25 |
| asset duration | 125/25 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/25, 1/25, 2/25, 3/25 |
| reader PTS (first 10) | 0/25, 0/25, 4/25, 2/25, 1/25, 3/25, 8/25, 6/25, 5/25, 7/25 |

Boundary round trip 120000 → 25 → 120000 (d = 4800 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/25 | 0 | 0 | 0.000000 |
| 1 | 4800 | 1/25 | 4800 | 0 | 0.000000 |
| 2 | 9600 | 2/25 | 9600 | 0 | 0.000000 |
| 100 | 480000 | 100/25 | 480000 | 0 | 0.000000 |
| 1000 | 4800000 | 1000/25 | 4800000 | 0 | 0.000000 |

### generated 29.97 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 30000 |
| nominalFrameRate | 29.97003 |
| minFrameDuration | 1001/30000 |
| asset duration | 150150/30000 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/30000, 2002/30000, 3003/30000, 4004/30000 |
| reader PTS (first 10) | 0/30000, 0/30000, 4004/30000, 2002/30000, 1001/30000, 3003/30000, 8008/30000, 6006/30000, 5005/30000, 7007/30000 |

Boundary round trip 120000 → 30000 → 120000 (d = 4004 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/30000 | 0 | 0 | 0.000000 |
| 1 | 4004 | 1001/30000 | 4004 | 0 | 0.000000 |
| 2 | 8008 | 2002/30000 | 8008 | 0 | 0.000000 |
| 100 | 400400 | 100100/30000 | 400400 | 0 | 0.000000 |
| 1000 | 4004000 | 1001000/30000 | 4004000 | 0 | 0.000000 |

### generated 30 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 30 |
| nominalFrameRate | 30.0 |
| minFrameDuration | 1/30 |
| asset duration | 150/30 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/30, 2/30, 3/30, 4/30 |
| reader PTS (first 10) | 0/30, 0/30, 4/30, 2/30, 1/30, 3/30, 8/30, 6/30, 5/30, 7/30 |

Boundary round trip 120000 → 30 → 120000 (d = 4000 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/30 | 0 | 0 | 0.000000 |
| 1 | 4000 | 1/30 | 4000 | 0 | 0.000000 |
| 2 | 8000 | 2/30 | 8000 | 0 | 0.000000 |
| 100 | 400000 | 100/30 | 400000 | 0 | 0.000000 |
| 1000 | 4000000 | 1000/30 | 4000000 | 0 | 0.000000 |

### generated 50 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 50 |
| nominalFrameRate | 50.0 |
| minFrameDuration | 1/50 |
| asset duration | 250/50 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/50, 1/50, 3/50, 5/50 |
| reader PTS (first 10) | 0/50, 0/50, 4/50, 2/50, 1/50, 3/50, 8/50, 6/50, 5/50, 7/50 |

Boundary round trip 120000 → 50 → 120000 (d = 2400 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/50 | 0 | 0 | 0.000000 |
| 1 | 2400 | 1/50 | 2400 | 0 | 0.000000 |
| 2 | 4800 | 2/50 | 4800 | 0 | 0.000000 |
| 100 | 240000 | 100/50 | 240000 | 0 | 0.000000 |
| 1000 | 2400000 | 1000/50 | 2400000 | 0 | 0.000000 |

### generated 59.94 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 60000 |
| nominalFrameRate | 59.94006 |
| minFrameDuration | 1001/60000 |
| asset duration | 300300/60000 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/60000, 1001/60000, 4004/60000, 6006/60000 |
| reader PTS (first 10) | 0/60000, 0/60000, 4004/60000, 2002/60000, 1001/60000, 3003/60000, 8008/60000, 6006/60000, 5005/60000, 7007/60000 |

Boundary round trip 120000 → 60000 → 120000 (d = 2002 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/60000 | 0 | 0 | 0.000000 |
| 1 | 2002 | 1001/60000 | 2002 | 0 | 0.000000 |
| 2 | 4004 | 2002/60000 | 4004 | 0 | 0.000000 |
| 100 | 200200 | 100100/60000 | 200200 | 0 | 0.000000 |
| 1000 | 2002000 | 1001000/60000 | 2002000 | 0 | 0.000000 |

### generated 60 fps (explicit timescale)

| metric | value |
|---|---|
| naturalTimeScale | 60 |
| nominalFrameRate | 60.0 |
| minFrameDuration | 1/60 |
| asset duration | 300/60 |
| AVPlayer currentTime timescale (paused, before play) | 1 |
| AVPlayer currentTime timescale (paused, after play) | 1000000000 |
| AVPlayer currentTime timescale (playing) | 1, 1000000000 |
| video output display timestamps | 0/60, 1/60, 4/60, 7/60 |
| reader PTS (first 10) | 0/60, 0/60, 4/60, 2/60, 1/60, 3/60, 8/60, 6/60, 5/60, 7/60 |

Boundary round trip 120000 → 60 → 120000 (d = 2000 ticks):

| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |
|---|---|---|---|---|---|
| 0 | 0 | 0/60 | 0 | 0 | 0.000000 |
| 1 | 2000 | 1/60 | 2000 | 0 | 0.000000 |
| 2 | 4000 | 2/60 | 4000 | 0 | 0.000000 |
| 100 | 200000 | 100/60 | 200000 | 0 | 0.000000 |
| 1000 | 2000000 | 1000/60 | 2000000 | 0 | 0.000000 |

## Real local media

No real camera/screen-recording files found in ~/Movies, ~/Desktop, ~/Downloads. NOT measured — rerun on a machine with real footage before trusting generated-only numbers.

## Flags

- ⚠️ generated 23.976 fps (default timescale): N=1 round trip through timescale 600 does NOT return the original (5005 → 5000)
- ⚠️ generated 23.976 fps (default timescale): N=2 round trip through timescale 600 does NOT return the original (10010 → 10000)
- ⚠️ generated 23.976 fps (default timescale): N=100 round trip through timescale 600 does NOT return the original (500500 → 500600)
- ⚠️ generated 23.976 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 24 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 25 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 29.97 fps (default timescale): N=1 round trip through timescale 600 does NOT return the original (4004 → 4000)
- ⚠️ generated 29.97 fps (default timescale): N=2 round trip through timescale 600 does NOT return the original (8008 → 8000)
- ⚠️ generated 29.97 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 30 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 50 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 59.94 fps (default timescale): N=1 round trip through timescale 600 does NOT return the original (2002 → 2000)
- ⚠️ generated 59.94 fps (default timescale): N=2 round trip through timescale 600 does NOT return the original (4004 → 4000)
- ⚠️ generated 59.94 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 60 fps (default timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=600, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=600, track.naturalTimeScale=600, videoOutput.displayTime=600
- ⚠️ generated 23.976 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=24000, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=24000, track.naturalTimeScale=24000, videoOutput.displayTime=24000
- ⚠️ generated 24 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=24, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=24, track.naturalTimeScale=24, videoOutput.displayTime=24
- ⚠️ generated 25 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=25, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=25, track.naturalTimeScale=25, videoOutput.displayTime=25
- ⚠️ generated 29.97 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=30000, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=30000, track.naturalTimeScale=30000, videoOutput.displayTime=30000
- ⚠️ generated 30 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=30, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=30, track.naturalTimeScale=30, videoOutput.displayTime=30
- ⚠️ generated 50 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=50, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=50, track.naturalTimeScale=50, videoOutput.displayTime=50
- ⚠️ generated 59.94 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=60000, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=60000, track.naturalTimeScale=60000, videoOutput.displayTime=60000
- ⚠️ generated 60 fps (explicit timescale): APIs report DIFFERENT timescales for the same asset — asset.duration=60, player.currentTime(pausedAfterPlay)=1000000000, player.currentTime(playing)=1/1000000000, reader.PTS=60, track.naturalTimeScale=60, videoOutput.displayTime=60
