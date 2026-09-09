# Aria Mac

A standalone macOS SwiftUI version of Aria.

Open `AriaMac.xcodeproj`, build the `AriaMac` scheme, and run it on macOS.
The app currently connects to the same song server as the iPhone app. It tries
Tailscale first, then falls back to the local Wi-Fi address:

```text
http://100.93.250.104:8000
http://192.168.0.16:8000
```

This first Mac version includes:

- paged loading from `/api/tracks`
- songs, albums, playlists, and queue sections
- clickable artist names with portrait pages, downloaded music, and albums available to download
- album cards open an album detail page before playback
- queued server-side album downloads with progress and ETA from the sidebar
- in-app YouTube Music album search with artwork, metadata, and one-click queueing
- sample-accurate album playback through one continuous AVAudioEngine output
- automatic shared playback with remote control from another Aria device, plus an explicit separate-listening mode
- live low-to-high audio spectrum driven by decoded playback samples
- shuffle that mutates the queue
- drag upcoming songs to reorder the queue, with Add to Queue alongside Play Next in song menus
- repeat modes
- cached artwork
- the Aria app icon

Library pages behave like tabs for the lifetime of the window. Switching to Now
Playing, Songs, or a playlist keeps the open album and its track scroll position.
The album's Albums back button returns to the previous grid position, sort order,
and search. Songs and Albums have independent searches, and visited Songs and
playlist pages also keep their scroll positions.

The Mac player uses a spinning artwork-label vinyl, a scrollable queue that follows
its edge, and transport controls below the queue. Lyrics sit under the record and
can expand into a reading view. The vinyl pauses with playback and respects Reduce
Motion. The library and its compact player keep their existing layout.

Run the player geometry checks without starting playback:

```sh
xcrun swiftc AriaMac/Support/VinylPlayerGeometry.swift Tests/VinylPlayerGeometryTests.swift -o /tmp/aria-vinyl-tests
/tmp/aria-vinyl-tests
```

Drag an upcoming song onto another to move it to that position in either queue
view. The current song and playback position stay fixed. Add to Queue follows
the iPhone behavior: new songs follow Play Next and other manual additions,
before the remaining album or playlist tracks.

Run queue ordering checks without connecting to the song server or playing audio:

```sh
xcrun swiftc -module-cache-path /tmp/aria-queue-module-cache -parse-as-library AriaMac/Services/*.swift AriaMac/Models/*.swift AriaMac/Support/*.swift AriaMac/ViewModels/MacPlayerViewModel.swift Tests/MacQueueTests.swift -o /tmp/aria-mac-queue-tests
/tmp/aria-mac-queue-tests
```

## Navigation verification

`Tests/MacNavigationPreview.swift` hosts the real interface with 80 synthetic
albums, 30 tracks per album, and a playlist. It intercepts all network requests
and supplies no audio streams, so it does not contact the song server or play audio.
Compile it with all service, model, support, view-model and view sources, excluding
the normal app entry point (the same pattern as the queue checks above).

Check these interactions in a 1040×700 window:

- Scroll Albums, open an album, scroll its tracks, visit Now Playing, then Albums.
  The same album and track position should return, including repeated switches.
- Use the album's Albums back button. The grid should retain its position and sort.
- Search Albums, visit and search Songs, then return. Each page keeps its own query.
- Visit a playlist or an artist from the album, then return. The album stays open.
- While another page is visible, hidden pages must not receive clicks, keyboard
  shortcuts, or accessibility focus. Deleting an album should return to the grid.

## Seamless album playback

Playback begins as soon as the selected song has downloaded and decoded to a
temporary PCM file. Albums, playlists, and mixed queues then prepare the next two
songs in the background. They use the same audio clock for sample-accurate
transitions, without waiting for the rest of an album before the first sound.
Buffering can still occur if the network cannot supply an upcoming song in time.

Each buffered track has its own player node. Adding, removing, reordering,
shuffling, or changing repeat replaces only future audio; the current song keeps
playing at its existing position. Unchanged buffered tracks and in-progress
preparation are reused. Queue edits during initial buffering also retain the
selected song's download, and pause/resume never waits for background preparation.

The first track's sample rate is preserved (including high-resolution audio).
Mixed-rate tracks are converted to that clock and stereo output. Codec padding is
handled by Apple's decoder; silence authored into a recording is preserved.
Temporary decoded files are retained for the small playback lookahead. A failure
preparing a future song is reported after buffered music finishes, and removing
that song allows preparation to continue. This applies when the Mac produces
audio; remote controls use the playback engine of their current host.

Offline rendering checks (no audible output):

```sh
xcrun swiftc -parse-as-library AriaMac/Services/GaplessAudioPlayer.swift AriaMac/Services/GaplessAudioFiles.swift AriaMac/Models/Track.swift AriaMac/Support/TimeFormatting.swift Tests/GaplessAudioPlayerTests.swift -o /tmp/aria-gapless-tests
/tmp/aria-gapless-tests
```

The checks compare every output sample at track boundaries, and cover buffering,
queue edits, cancellation, pause/resume, seeking, repeat, format conversion, and
AAC priming/remainder frames. Scheduling uses Apple's
[AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).

## Performance

Playback uses property-level Observation so time updates do not invalidate the
library or queue. The record rotates through Core Animation, and visual work is
suspended when its window is hidden or minimized. Spectrum analysis is capped at
20 updates per second, reuses its window and filter coefficients, and is detached
when no visible visualizer needs it (including Reduce Motion). Pausing suspends
the audio engine; stopping or finishing the queue shuts it down.

Artwork is decoded into display-sized variants (96, 256, 512, or 1024 pixels)
instead of full-resolution images. Concurrent requests share downloads and
thumbnail decoding. The decoded-image cache has a 24 MiB cost budget; image
references held by visible views and other app memory are additional.

Playback sync reuses queue IDs and catalog lookups, skips unchanged state, and
polls less often for a single idle/background host. Multiple-device sessions
retain the 500 ms polling interval. The slowest healthy heartbeat is 2 seconds,
below the server's 8-second device expiry.

Build an optimized app for Activity Monitor comparisons:

```sh
xcodebuild -project AriaMac.xcodeproj -scheme AriaMac -configuration Release \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Run the resulting `DerivedData/Build/Products/Release/AriaMac.app` directly,
without the Xcode debugger. Compare the same song, queue, artwork cache, window
visibility, and visualizer setting after preparation finishes. Check paused,
playing, and minimized states separately; background audio decoding is temporary
work. Activity Monitor's Energy Impact includes more than process CPU.

Focused performance regressions:

```sh
xcrun swiftc -module-cache-path /tmp/aria-performance-module-cache -parse-as-library \
  AriaMac/Services/*.swift AriaMac/Models/*.swift AriaMac/Support/*.swift \
  AriaMac/ViewModels/MacPlayerViewModel.swift Tests/MacPerformanceTests.swift \
  -o /tmp/aria-mac-performance-tests
/tmp/aria-mac-performance-tests
```

These checks cover observation isolation, multiple-window visibility, visualizer
update limits at 44.1/96/192 kHz, concurrent image reuse, thumbnail dimensions,
and malformed artwork. Also run the queue, vinyl geometry, and offline audio
checks above when changing these paths.

Local benchmark on 2026-09-06 (short samples, not a whole-app energy guarantee):
with 1,725 synthetic queue entries, identical 1040×700 windows, no network/audio,
and `swiftc -O` for both versions, the previous UI used 15.8–18.5% process CPU and
the optimized UI used 3.6–4.9%. The optimized paused UI used 0–0.1%. Both synthetic
previews used about 43 MiB; this fixture has no downloaded artwork. The standalone
96 kHz spectrum benchmark processed 10,000 buffers in 1.45 seconds before versus
0.30 seconds after. Real playback and Energy Impact must be measured separately.

The isolated UI fixture is `Tests/MacPerformancePreview.swift` (compile with all
service, model, support, view-model and view sources, excluding the normal app
entry point). It intercepts network requests and never produces audio. The
analyzer benchmark can be reproduced with:

```sh
xcrun swiftc -O -parse-as-library AriaMac/Services/AudioSpectrumAnalyzer.swift \
  Tests/AudioSpectrumBenchmark.swift -o /tmp/aria-spectrum-benchmark
/tmp/aria-spectrum-benchmark
```
