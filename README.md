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
- AVPlayer playback
- live low-to-high audio spectrum driven by decoded playback samples
- shuffle that mutates the queue
- repeat modes
- cached artwork
- the Aria app icon
