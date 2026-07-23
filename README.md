# whispermlx-ui

A small macOS launcher for local transcription on Apple Silicon using [whispermlx](https://github.com/KalebJS/whispermlx). The UI follows the macOS system language: German when the preferred language starts with `de`, otherwise English.

## Install

Prerequisites: macOS on Apple Silicon, `ffmpeg`, and `whispermlx` installed in the Codex workbench.

```zsh
./install.sh
```

Launch the UI:

```zsh
whispermlx-ui
```

Or start **WhisperMLX UI** from Finder, Spotlight, or Launchpad. The installer copies it to `/Applications`.

For command-line use:

```zsh
whispermlx /path/to/audio-or-video-file
```

The UI automatically detects the spoken language, lets you select a model and optionally speaker diarization. Outputs (`.txt`, `.srt`, `.vtt`, `.tsv`, `.json`) are written to a `.transkript` folder next to the original.

## Speaker diarization

Copy the template and insert a Hugging Face **read** token approved for `pyannote/speaker-diarization-community-1`:

```zsh
cp config/hf.env.example ~/.config/whispermlx-ui/hf.env
chmod 600 ~/.config/whispermlx-ui/hf.env
```

The token file is deliberately ignored by Git.
