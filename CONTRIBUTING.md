# Contributing to Scripta

Thanks for your interest in contributing! Scripta is a small project and every contribution matters — whether it's a bug fix, a feature idea, better docs, or just a question.

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15.4+ (for Swift 5.9 toolchain)
- [Ollama](https://ollama.com) installed and running (for AI features)

### Build & Run

```bash
git clone https://github.com/thehwang/Scripta.git
cd Scripta
make run
```

This will:
1. Create a local signing certificate (first time only)
2. Build the app with Swift Package Manager
3. Sign and launch `Scripta.app`

### Project Layout

```
Sources/
├── Scripta/              # Main application
│   ├── AppDelegate.swift          # App lifecycle, window management
│   ├── ContentView.swift          # Main UI (full + minimal modes)
│   ├── MeetingRecorder.swift      # Recording orchestration
│   ├── SystemAudioCapture.swift   # ScreenCaptureKit system audio
│   ├── SummaryService.swift       # Ollama AI integration
│   ├── SummaryModelManager.swift  # Model selection & health check
│   ├── ChatPanel.swift            # AI Q&A sidebar
│   ├── HistoryPanel.swift         # Meeting history browser
│   ├── HistoryDetailView.swift    # Single session detail view
│   ├── MeetingStore.swift         # Session data layer
│   ├── ScriptExporter.swift       # Transcript/audio export
│   ├── TranslationService.swift   # Apple Translation wrapper
│   └── Info.plist
└── ScriptaCore/          # Shared types
    └── TranscriptEntry.swift
```

## How to Contribute

### Reporting Bugs

Open a [Bug Report](https://github.com/thehwang/Scripta/issues/new?template=bug_report.yml) with:

- What happened vs. what you expected
- Steps to reproduce
- Your macOS version and chip (Apple Silicon / Intel)
- Console logs if available (`Console.app` → filter by "Scripta")

### Suggesting Features

Open a [Feature Request](https://github.com/thehwang/Scripta/issues/new?template=feature_request.yml). Describe the use case — the "why" matters more than the "how."

### Submitting Code

1. **Fork** the repo and create a branch from `main`:
   ```bash
   git checkout -b fix/your-description
   ```

2. **Make your changes.** Keep commits focused — one logical change per commit.

3. **Test locally:**
   ```bash
   make run
   ```
   Verify the app launches, recording works, and your change behaves as expected.

4. **Push and open a PR** against `main`. Describe what you changed and why.

### What Makes a Good PR

- Small and focused (< 300 lines is ideal)
- Includes a clear description of the problem and solution
- Doesn't break existing functionality
- Follows the existing code style (see below)

## Code Style

- **Swift 5.9**, targeting macOS 14+
- Use SwiftUI for all new UI components
- Prefer `@Published` properties over callbacks for observable state
- Use `async/await` for asynchronous work; avoid raw `DispatchQueue` unless interfacing with C APIs
- No third-party dependencies unless absolutely necessary — the zero-dependency approach is intentional
- Comments should explain *why*, not *what*

## Areas Where Help is Welcome

Looking for something to work on? These areas would benefit from contributions:

- **Whisper integration** — Add [whisper.cpp](https://github.com/ggerganov/whisper.cpp) as an optional transcription engine
- **Export formats** — SRT subtitles, PDF reports, Markdown with timestamps
- **Keyboard shortcuts** — Global hotkeys for start/stop recording
- **Localization** — Translate the UI into other languages
- **Accessibility** — VoiceOver support, keyboard navigation improvements

Check the [Issues](https://github.com/thehwang/Scripta/issues) page for tasks tagged `good first issue`.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
