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
- repeat modes
- cached artwork
- the Aria app icon

The Mac player uses a spinning artwork-label vinyl, a scrollable queue that follows
its edge, and transport controls below the queue. Lyrics sit under the record and
can expand into a reading view. The vinyl pauses with playback and respects Reduce
Motion. The library and its compact player keep their existing layout.

Run the player geometry checks without starting playback:

```sh
xcrun swiftc AriaMac/Support/VinylPlayerGeometry.swift Tests/VinylPlayerGeometryTests.swift -o /tmp/aria-vinyl-tests
/tmp/aria-vinyl-tests
```

## Seamless album playback

Albums are downloaded and decoded to temporary PCM files before playback begins.
The player shows preparation progress, then schedules every remaining album track
on one audio clock. Album boundaries never depend on a network request or a UI
callback. This can add an initial buffering delay and uses temporary disk space;
opening a different queue releases audio that is no longer needed.

The first track's sample rate is preserved (including high-resolution audio).
Mixed-rate tracks are converted to that clock and stereo output. Codec padding is
handled by Apple's decoder; silence authored into a recording is preserved.
Playlists and mixed queues prepare three tracks ahead and can still buffer if the
network falls behind. This applies when the Mac is the device producing audio;
remote controls continue to use the playback engine of their current host.

Offline rendering checks (no audible output):

```sh
xcrun swiftc -parse-as-library AriaMac/Services/GaplessAudioPlayer.swift AriaMac/Services/GaplessAudioFiles.swift AriaMac/Models/Track.swift AriaMac/Support/TimeFormatting.swift Tests/GaplessAudioPlayerTests.swift -o /tmp/aria-gapless-tests
/tmp/aria-gapless-tests
```

The checks compare every output sample at track boundaries, and cover buffering,
queue edits, cancellation, pause/resume, seeking, repeat, format conversion, and
AAC priming/remainder frames. Scheduling uses Apple's
[AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).
