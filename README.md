# WhisperMLX UI

A native macOS app for local transcription on Apple Silicon using [whispermlx](https://github.com/KalebJS/whispermlx). The interface follows the macOS app language and is localized in German and English.

## Current Features

- Import audio and video files directly from the app
- Record locally from the microphone and system audio
- Pick a specific microphone in Settings or fall back to the current macOS default input
- Show progress and runtime logs during transcription
- Download and remove Whisper models from the settings window
- Optional speaker diarization with pyannote, either through a local offline clone or a Hugging Face token
- Write results into a transcript folder next to the source file

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Xcode 16 or newer
- `xcodegen` to generate the Xcode project from [`project.yml`](./project.yml)

The app is intended to be self-contained and bundles its own `whispermlx` launcher and `ffmpeg`.

## Development and Build

Regenerate the project files:

```zsh
xcodegen generate
```

Build Debug or Release with the helper script:

```zsh
./build.sh
./build.sh Release
```

The script regenerates the Xcode project first and then builds the `WhisperMLXUI` scheme.

Important: the build expects a bundled FFmpeg binary at [`bin/ffmpeg`](./bin/ffmpeg). If it is missing or needs to be rebuilt:

```zsh
./scripts/build-bundled-ffmpeg.sh
```

After that, you can also open and run the app directly from [`WhisperMLXUI.xcodeproj`](./WhisperMLXUI.xcodeproj) in Xcode.

## Usage

1. Choose a file or start a recording
2. Select an installed model in Settings
3. Optionally pick a dedicated microphone in Settings
4. Optionally enable speaker diarization
5. Start transcription

For recordings, the app first stores microphone and system-audio tracks separately and then mixes them with `ffmpeg` into a Whisper-ready WAV file.

## Models

The app currently exposes these models:

- `large-v3`
- `large-v3-turbo`
- `small`

Model data is stored in the Hugging Face cache under `~/.cache/huggingface/hub`. You can download or remove models from the settings window.

## Speaker Diarization

Speaker diarization uses `pyannote/speaker-diarization-community-1`.

You can use it in two ways:

- Online or first-time setup: accept the model terms on Hugging Face and provide a token in the app settings
- Offline after setup: let the app download the pipeline once into its managed local storage

The token is stored only in the macOS Keychain. After the first download, the app uses its managed local pyannote directory and no token is required for offline transcription.

## Auto Updates

The app includes Sparkle 2 for native macOS update checks.

- The default feed URL is `https://sirhexalot.github.io/whispermlx-ui/appcast.xml`
- The app exposes a `Check for Updates…` menu item in the application menu
- Release archives can be published for Sparkle from the notarized ZIP build

To host the update feed on GitHub Pages, enable Pages for the repository and publish from the `docs/` folder on `main`.

To generate or refresh the Sparkle appcast after creating a notarized ZIP:

```zsh
./scripts/publish-sparkle-appcast.sh
```

Sparkle's EdDSA public key still needs to be generated once and written to `SUPublicEDKey` for production update validation.

## Permissions

For local recording, the app needs:

- microphone access
- screen and system-audio recording permission

Without those permissions, combined recording will not work reliably.
