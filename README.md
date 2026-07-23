# WhisperMLX UI

A native macOS SwiftUI app for local audio and video transcription on Apple Silicon using [whispermlx](https://github.com/KalebJS/whispermlx). The interface is localized in English and German and follows the macOS app language.

## Requirements

- macOS 14 or newer on Apple Silicon
- Python 3.13 with `whispermlx` installed
- `ffmpeg` available on `PATH`

Install the runtime dependencies once:

```zsh
brew install python@3.13 ffmpeg
/opt/homebrew/opt/python@3.13/bin/python3.13 -m pip install --upgrade whispermlx
```

If you use a custom Python environment, set `WHISPERMLX_PYTHON` to that Python executable before launching the app.

## Build

Open `WhisperMLXUI.xcodeproj` in Xcode and run the `WhisperMLXUI` scheme.

The app imports audio or video files, can record locally from the microphone, runs transcription in the background, and shows progress and logs in the window. Results are written next to the original file using a localized transcript folder name.

## DMG

Create a distributable DMG from the command line:

```zsh
xcodebuild -project WhisperMLXUI.xcodeproj -scheme WhisperMLXUI -configuration Release -derivedDataPath build build
mkdir -p dist/dmg-root
cp -R "build/Build/Products/Release/WhisperMLX UI.app" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "WhisperMLX UI" -srcfolder dist/dmg-root -ov -format UDZO dist/WhisperMLXUI.dmg
```

The generated disk image can be opened in Finder and the app can be copied to `/Applications`.

## Speaker Diarization

Speaker diarization uses pyannote and requires a Hugging Face read token approved for `pyannote/speaker-diarization-community-1`. Store the token in the app settings. The token is saved in the macOS keychain.
