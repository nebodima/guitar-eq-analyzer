# Guitar EQ Analyzer

Native macOS real-time spectrum analyzer and EQ tuning tool — built with SwiftUI and AVAudioEngine.

## Features

- Real-time FFT spectrum (pre-EQ + post-EQ, mathematically accurate)
- 7-band parametric EQ with live curve overlay (80 Hz – 6.4 kHz)
- AutoEQ — automatic band correction with Guitar / Vocal / Flat profiles (4 / 8 / 16 sec analysis)
- Mic input with VU-meter and monitor mode
- File playback with seamless loop
- Recording to WAV (pre-EQ dry signal) → auto-loads for playback
- Named presets with "My Preset" default (loads on startup)
- Snapshot comparison, EQ undo, Copy EQ to clipboard
- Resonance peak highlighting (Original or Equalized)
- Input device selection, CPU/RAM usage indicator

## Build & Run

```bash
cd guitar-eq-analyzer
swift build
swift run
```

Requires macOS 13+.

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Space` | Play / Stop file |
| `⌘M` | MIC on / off |
| `⌘R` | Record / Stop recording |
| `⌘↵` | Run AutoEQ |
| `⌘Z` | Undo last EQ change |

## Recordings

Saved to `~/Documents/GuitarEQ Recordings/` (WAV, 32-bit float).  
Click the folder icon in the toolbar to open in Finder.

## Legacy Python version

The original Python prototype lives in [`/legacy`](./legacy/).
