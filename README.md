# WhisperMLX UI 🎙️📝

**Turn meetings, interviews, and recordings into clean, readable text — locally on your Mac.**  
No cloud. No “upload your private audio somewhere”. Just fast on-device AI.

Ever had that moment where you’re in a meeting and you either…

- write notes and miss half the conversation, or
- try to “just remember it all” (spoiler: you won’t), or
- discover your pencil is blunt again at the worst possible time?

WhisperMLX UI is for people who want to stay present in the conversation — and still walk away with a solid written summary of what was said.

---

## Why you’ll like it

- **Local-first privacy** 🔒  
  Your audio stays on your machine. No cloud AI required.
- **Ridiculously simple workflow** ✅  
  Choose a file _or_ record → pick a model → start → get text.
- **Works with recordings you already have**  
  Meeting recordings, lectures, podcasts, interviews, voice memos, screen recordings…
- **Optional speaker separation** (who said what)  
  Great when multiple people are talking.

---

## What it does (without the jargon)

WhisperMLX UI uses on-device AI to **convert speech into text**.  
(Yes, people call it “transcription”… but honestly, “turn audio into text” is what you actually want.)

You can:

- **Record a meeting** (mic + system audio)
- **Import audio/video files** and turn them into text
- Save results neatly in a **transcript folder next to your original file**

---

## Core features

- Import audio/video from inside the app
- Record from **microphone + system audio**
- Choose a specific microphone (or just use the Mac default)
- See progress + runtime logs while it works (so it doesn’t feel like it’s “stuck”)
- Download/remove AI models in Settings
- Optional speaker diarization (speaker detection)
- Outputs saved next to the source file for easy organization

---

## Privacy & “No Cloud” promise 🔒

This app is built for **local processing** on Apple Silicon Macs.  
Your recordings don’t need to leave your computer to become text.

---

## Requirements

- **Apple Silicon Mac**
- **macOS 14+**

---

## Quick start

1. **Choose a file** _or_ **start a recording**
2. Open **Settings** and select an installed model
3. (Optional) Pick a dedicated microphone
4. (Optional) Enable speaker detection
5. Hit **Start** — get readable text output

---

## Models

Available models in the app:

- `large-v3`
- `large-v3-turbo`
- `small`

(You can download/remove models from Settings.)

---

## Speaker detection (optional)

If you want “Speaker 1 / Speaker 2” style separation, enable speaker diarization.  
It can be set up with a Hugging Face token (and can work offline after initial setup).

---

## Updates

Built-in update checks via Sparkle (native macOS experience).

---

## Developer notes (kept minimal on purpose)

If you want to build from source, you’ll need:

- Xcode 16+
- `xcodegen`

Generate project:

```zsh
xcodegen generate
```

Build:

```zsh
./build.sh
./build.sh Release
```

---
