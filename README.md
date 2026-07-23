# whispermlx-ui

A small macOS launcher for local transcription on Apple Silicon using [whispermlx](https://github.com/KalebJS/whispermlx). The UI is available in German and English.

## Install

Prerequisites: macOS on Apple Silicon, `ffmpeg`, and `whispermlx` installed in the Codex workbench.

```zsh
./install.sh
```

Launch the UI:

```zsh
transkribiere-ui
```

It lets you select an audio/video file, model, and optionally speaker diarization. Outputs (`.txt`, `.srt`, `.vtt`, `.tsv`, `.json`) are written to a `.transkript` folder next to the original.

## Speaker diarization

Copy the template and insert a Hugging Face **read** token approved for `pyannote/speaker-diarization-community-1`:

```zsh
cp config/hf.env.example ~/.config/whispermlx-ui/hf.env
chmod 600 ~/.config/whispermlx-ui/hf.env
```

The token file is deliberately ignored by Git.
