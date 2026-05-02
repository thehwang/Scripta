<p align="center">
  <img src="build/AppIcon.iconset/icon_256x256.png" width="128" alt="MeetingPilot icon">
</p>

<h1 align="center">Meeting Pilot</h1>

<p align="center">
  <strong>Privacy-first meeting transcription & AI summary for macOS</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#installation">Installation</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#building-from-source">Build</a> •
  <a href="#license">License</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/AI-Ollama-green" alt="Ollama">
  <img src="https://img.shields.io/github/license/thehwang/MeetingPilot" alt="MIT License">
</p>

---

Meeting Pilot is a native macOS app that captures **both your microphone and system audio** during meetings, transcribes them in real-time using Apple's on-device speech recognition, and generates AI-powered summaries — all running **100% locally** on your Mac. No cloud. No subscriptions. No data leaves your machine.

## Features

**Real-time Transcription**
- Dual-channel capture: your mic ("You") + system audio ("Remote")
- On-device speech recognition via `SFSpeechRecognizer`
- Supports 10+ languages (English, Chinese, Japanese, Korean, Spanish, French, German, and more)

**AI-Powered Summaries**
- Local AI summaries powered by [Ollama](https://ollama.com)
- Streaming responses displayed in real-time
- Key points + action items extraction

**AI Chat Panel**
- Ask questions about your meeting transcript
- Multi-turn conversation with context
- Works during recording or on past meetings

**Live Translation** *(macOS 15+)*
- Real-time bilingual transcript using Apple Translation framework
- Context-aware translation for improved quality

**Meeting History**
- Browse and search all past sessions
- View transcripts, summaries, and re-generate with AI
- Sessions saved to `~/Documents/MeetingPilotScripts/`

**Two Display Modes**
- **Full mode**: complete UI with transcript, summary, controls
- **Minimal mode**: floating live captions bar — stays on top while you work

**Privacy by Design**
- All processing happens on your Mac
- No internet connection required (except for Ollama model download)
- No account, no telemetry, no tracking

## Installation

### Quick Install (recommended)

Download the latest release from the [Releases](https://github.com/thehwang/MeetingPilot/releases) page and run:

```bash
cd ~/Downloads/MeetingPilot
chmod +x install.sh
./install.sh
```

The install script will:
- Copy `MeetingPilot.app` to `/Applications`
- Install [Ollama](https://ollama.com) via Homebrew (if not already installed)
- Start Ollama as a background service
- Pull the default AI model (`qwen2.5:3b`)

### Manual Install

1. Download and move `MeetingPilot.app` to `/Applications`
2. Install Ollama: `brew install ollama && brew services start ollama`
3. Pull a model: `ollama pull qwen2.5:3b`
4. Launch Meeting Pilot

## Requirements

| Component | Requirement |
|-----------|------------|
| macOS | 14.0 (Sonoma) or later |
| Chip | Apple Silicon (M1/M2/M3/M4) or Intel |
| Ollama | Required for AI summaries and chat |
| Disk | ~2GB for AI model |
| Translation | macOS 15+ (Sequoia) for live translation |

## Building from Source

```bash
git clone https://github.com/thehwang/MeetingPilot.git
cd MeetingPilot
make run
```

This will build the app with Swift Package Manager, sign it with an ad-hoc certificate, and launch it.

### Project Structure

```
MeetingPilot/
├── Sources/
│   ├── MeetingPilot/         # Main app
│   │   ├── AppDelegate.swift
│   │   ├── ContentView.swift       # Main UI (full + minimal modes)
│   │   ├── MeetingRecorder.swift    # Recording orchestration
│   │   ├── SystemAudioCapture.swift # ScreenCaptureKit audio
│   │   ├── SummaryService.swift     # Ollama AI integration
│   │   ├── ChatPanel.swift          # AI Q&A sidebar
│   │   ├── HistoryPanel.swift       # Meeting history browser
│   │   ├── TranslationService.swift # Apple Translation wrapper
│   │   └── ...
│   └── MeetingPilotCore/     # Shared types
├── Resources/
│   └── AppIcon.icns
├── Makefile
└── Package.swift
```

## Permissions

Meeting Pilot requires the following macOS permissions (prompted on first launch):

- **Microphone** — to capture your voice
- **Screen Recording** — to capture system/meeting audio via ScreenCaptureKit
- **Speech Recognition** — for on-device transcription
- **Accessibility** — for enhanced speech recognition (optional)

## License

[MIT](LICENSE) — free for personal and commercial use.

---

<p align="center">
  Made with ❤️ on a Mac
</p>
