# Meeting Pilot

macOS native meeting transcription app with dual-channel audio capture and speaker diarization.

## Features

- Dual-channel real-time transcription: Microphone ("You") + System Audio ("Remote")
- On-device speech recognition via Apple `SFSpeechRecognizer` (no cloud API needed)
- Post-recording speaker diarization using MFCC + YIN pitch + agglomerative clustering
- System audio capture via `ScreenCaptureKit` (captures Zoom, Teams, Meet, etc.)
- Auto-export transcript to `~/Documents/MeetingPilotScripts/`
- Menu bar app with live transcript display

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)
- Permissions: Microphone, Speech Recognition, Screen Recording

## Install

```bash
git clone git@github.com:hwang-cadent/MeetingPilot.git
cd MeetingPilot
make install
```

`make install` will automatically:
1. Create a local self-signed code signing certificate (first time only)
2. Build a release binary
3. Package and sign as `MeetingPilot.app`
4. Install to `/Applications/`

On first launch, grant Microphone and Screen Recording permissions when prompted.

## Development

```bash
make build    # Build debug binary
make run      # Build, package, sign, and launch (debug)
make clean    # Remove build artifacts
```

## Architecture

```
Sources/
  MeetingPilotCore/    # Shared library
    TranscriptEntry.swift
    SpeakerDiarizer.swift
    Logging.swift
  MeetingPilot/        # Main app
    main.swift
    AppDelegate.swift
    ContentView.swift
    MeetingRecorder.swift
    SystemAudioCapture.swift
    ScriptExporter.swift
  DiarizeTest/         # CLI tool for diarization testing
    main.swift
Tests/
  test_diarizer.sh     # Automated diarization test script
  generate_test_audio.py
  compare_results.py
```

## How It Works

1. **Recording**: Captures microphone (your voice) and system audio (remote participants) simultaneously
2. **Real-time transcription**: Both channels are transcribed independently using on-device `SFSpeechRecognizer`
3. **Speaker diarization**: After recording stops, the system audio is analyzed to identify different remote speakers using:
   - Energy-based Voice Activity Detection (VAD)
   - Spectral change-point detection
   - MFCC + Delta-MFCC feature extraction
   - YIN pitch estimation
   - Agglomerative hierarchical clustering with adaptive threshold
4. **Export**: Final transcript with speaker labels is saved as Markdown

## Testing

```bash
# Automated test with macOS TTS voices
cd Tests && ./test_diarizer.sh

# Test with a local WAV file
./test_diarizer.sh recording.wav

# Test with YouTube video (requires yt-dlp)
./test_diarizer.sh "https://youtube.com/watch?v=..."
```

## License

Private — All rights reserved.
