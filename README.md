# Aria Mac

A standalone macOS SwiftUI version of Aria.

Open `AriaMac.xcodeproj`, build the `AriaMac` scheme, and run it on macOS.
The app currently connects to the same song server as the iPhone app:

```text
http://100.93.250.104:8000
```

This first Mac version includes:

- paged loading from `/api/tracks`
- songs, albums, playlists, and queue sections
- AVPlayer playback
- shuffle that mutates the queue
- repeat modes
- cached artwork
- the Aria app icon
