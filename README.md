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
- album cards open an album detail page before playback
- queued server-side album downloads with progress and ETA from the sidebar
- AVPlayer playback
- shuffle that mutates the queue
- repeat modes
- cached artwork
- the Aria app icon
