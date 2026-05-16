# Scripta demo automation

A [Hammerspoon](https://www.hammerspoon.org/) Lua script that drives the
Scripta UI through the v3.2 Gemma 4 demo so every screen recording take
looks identical. The voiceover (`blog/voiceover-final.mp3`) acts as the
master clock; the script issues UI actions at the right offsets.

## Why bother

A 90-second demo with seven beats is hard to manually nail in one take.
Automating the input means you can record N times until ambient details
(window focus, system audio, etc.) all line up, without your timing drift
ruining the take.

## One-time setup (5 minutes)

```bash
# 1. Install Hammerspoon (free, open source).
brew install --cask hammerspoon

# 2. Launch it once and grant Accessibility permission:
#    System Settings → Privacy & Security → Accessibility → enable Hammerspoon.

# 3. Wire this script into your Hammerspoon config.
mkdir -p ~/.hammerspoon
cat >> ~/.hammerspoon/init.lua <<EOF
-- Scripta demo automation
dofile(os.getenv("HOME") .. "/Cursor/cdl_cursor_rules/MeetingPilot/demo/scripta-demo.lua")
EOF

# 4. Reload Hammerspoon config (menu bar icon → Reload Config).
#    You should see: "Scripta demo loaded — ⌥⌘D to run"
```

Adjust the path in step 3 if your `cdl_cursor_rules` checkout lives
elsewhere. The script also exposes `CONFIG.voiceoverPath` at the top of
`scripta-demo.lua` — edit that line if you move the mp3.

## Pre-run checklist

Run through this every time you sit down to record:

- [ ] Scripta v3.2.2+ is **installed and launched**. Earlier versions don't
      have the `accessibilityIdentifier` annotations the script relies on.
- [ ] Ollama is running (`ollama list` succeeds) and `gemma4:e2b` is pulled.
- [ ] Scripta's mic mute toggle is **unmuted** (icon in bottom bar shows
      a mic, not `mic.slash`). Otherwise the mic channel stays empty.
- [ ] **Speakers, not AirPods.** The script plays the voiceover through
      `afplay`; Scripta's System Audio capture picks it up via
      ScreenCaptureKit, so the voiceover itself fills the System Audio
      column in real time. No separate YouTube clip is needed. (If you
      use AirPods, system audio still routes correctly to capture, but
      it's worth verifying once.)
- [ ] Acoustic echo cancellation will keep the mic channel clean when the
      voiceover bleeds out of the speakers — that's by design, no action
      needed from you.
- [ ] Notifications silenced: Focus → Do Not Disturb.
- [ ] Existing transcript in Scripta is empty (use the History panel to
      clear if needed).
- [ ] **(Optional)** If using the Terminal peek cue, set
      `CONFIG.terminalAppName` to your terminal of choice ("Terminal",
      "iTerm", "Warp", "Ghostty") and have a window open in front
      tailing `~/Library/Logs/Scripta/scripta.log` so the `num_ctx=131072`
      line is visible when focused.

## Recording a take

1. Activate Scripta (frontmost window). The script will re-activate it
   between cues but starting from focus saves drama.
2. Press `⌥⌘D` (Option-Command-D).
3. A big black overlay reads "Start screen recording NOW. Demo begins
   in 3..." Hit `⌘⇧5` and start your screen recording in that 3-second
   window.
4. Watch the cues. At 27.5s the script will flash
   "🎤 Speak now: 'Let me try summarizing this meeting.'" — read that line
   into your mic. (The System Audio column is filling itself from the
   voiceover playing through your speakers, no action needed there.)
5. At 79s the script tells you to stop screen recording.

## If a take is bad

Press `⌥⌘.` (Option-Command-period) to abort. This kills:

- The `afplay` voiceover task
- All pending UI cue timers
- Any in-progress recording inside Scripta (sends a Stop click)

Then just start your screen recording again, press `⌥⌘D` again, and
re-record.

## Tuning the timings

`CONFIG.cues` near the top of `scripta-demo.lua` is the entire timing
contract. Adjust seconds, reload Hammerspoon, retry. The defaults are
sized for the current `blog/voiceover-final.mp3` (78.5s ElevenLabs
"Michael C. Vincent" voice at speed 95).

If you re-generate the voiceover with different pacing, run
`ffmpeg -af silencedetect=noise=-35dB:duration=0.5 -i voiceover-final.mp3 -f null -` to
get fresh paragraph break timestamps and update the cues.

## How it targets UI elements

The script identifies buttons through accessibility (AX) attributes —
no fragile pixel coordinates:

- Stable `AXIdentifier`s set in Swift via `.accessibilityIdentifier(...)`:
  - `"RecordButton"` (Start Recording)
  - `"StopButton"` (Stop Recording)
  - `"SummarizeButton"` (Summarize)
  - `"SetupDoneButton"` (Done in AI Model Settings)
  - `"InstalledModel.<name>"` (each row in the installed models list)
- Fallback via `AXTitle` matching (e.g. "Start Recording") if an
  identifier ever moves around between versions.

To inspect the AX tree yourself:

```lua
-- In Hammerspoon console:
hs.axuielement.applicationElement(hs.application.get("Scripta")):buildTree()
```

## When to skip this and just record manually

If you only need one take or you want the natural "human" cadence
(slight pauses, eye contact with the screen), do it by hand. This
automation pays off when you're chasing a "competition-quality" cut and
plan to do 5+ takes.
