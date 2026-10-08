# Repository notes

Native macOS SwiftUI app that wraps the bundled WhisperMLX CLI. The Xcode project is generated from `project.yml` with XcodeGen. The runnable app and its bundled `bin/whispermlx`, `bin/whispermlx_runtime.py`, and `bin/ffmpeg` only come from `build.sh` — do not assume `swift build` packages them.

## Build
- `./build.sh Debug` (or `./build.sh Release`): runs `xcodegen generate`, builds with derived data kept outside iCloud (`WHISPERMLXUI_DERIVED_DATA_PATH`, default `$TMPDIR/whispermlx-ui-derived-data`), copies to `dist/<configuration>/`, and verifies the staged signature. Re-run after editing `project.yml`.
- `bin/ffmpeg` and `bin/uv` are gitignored prerequisites. `build.sh` fetches `uv` via `scripts/build-bundled-uv.sh` when missing; if FFmpeg is absent, run `scripts/build-bundled-ffmpeg.sh` first.
- String catalogs `Sources/WhisperMLXUI/*.xcstrings` are authoritative (de + en); legacy `Resources/*.strings` are deliberately excluded to avoid duplicate tables.

## Runtime
- `WhisperMLXUIApp.swift` creates `TranscriptionController`, which launches `bin/whispermlx`. First-run setup (`RuntimeSetup.swift` -> `bin/setup-runtime`) installs pinned Python 3.13.14 / WhisperMLX 3.14.0 / MLX 0.32.3 under `~/.local/share/whispermlx-ui/runtime`.
- The wrapper picks that runtime, with `WHISPERMLX_PYTHON` overriding the interpreter for tests, and calls `bin/whispermlx_runtime.py` for checkpoints and CPU alignment. Never edit installed site-packages; hashes live in `runtime-requirements.txt` (regenerate from `runtime-requirements.in` with uv).

## Tests
- Swift: XCTest target `WhisperMLXUITests` in `tests/WhisperMLXUI` (it shares the lowercase `tests/` dir with the Python tests). Run: `xcodegen generate && xcodebuild test -project WhisperMLXUI.xcodeproj -scheme WhisperMLXUI -destination 'platform=macOS'`. Note the Swift module name is `WhisperMLX_UI` (the product name has a space), and the test target needs explicit `TEST_HOST`/`BUNDLE_LOADER`.
- Python runtime tests need NumPy; use the managed venv: `~/.local/share/whispermlx-ui/venv/bin/python -m unittest discover -s tests -p 'test_*.py'`. For one test, add `-k test_raw_cache_skips_model_loading_and_invalidates_changed_source`.

## Recording & output layout
- Recordings live in `~/Movies/WhisperMLX Recordings/<session>/` with the mixed `Recording.m4a` plus a `source/` folder of raw tracks (that subfolder name is localized). Every session folder carries a `.whispermlx-session` marker, and older localized roots are migrated automatically.
- Transcription writes beside the source in `<stem>.transkript/`. Alignment caches (`.alignment-cache/`) and `*.rohtranskript-*.json` are intermediate, not finished transcripts.
- The app is **not sandboxed** (entitlements only declare `audio-input`), so it has full filesystem access — guard destructive file operations (the audio-cleanup path moves files to the Trash, never deletes transcripts).

## Release
- Signed/notarized release: `scripts/create-release.sh Release`, which needs exported `APPLE_DEVELOPER_IDENTITY` and `APPLE_NOTARY_PROFILE`. `scripts/package-release.sh` only zips the development-signed build. The release script clears build caches and `dist/Debug` but keeps `dist/Release` and Sparkle files.
- Sparkle feed: `SPARKLE_DOWNLOAD_BASE_URL="https://github.com/Sirhexalot/whispermlx-ui/releases/download/v<version>" ./scripts/publish-sparkle-appcast.sh` (writes `docs/appcast.xml`; GitHub Pages serves `main` `/docs`). Then tag and `gh release create v<version> dist/Release/WhisperMLX-UI-macOS.zip`.
- Uploading the asset, pushing the tag, and updating the feed are separate steps — do not claim the release is published just because the ZIP exists.

## Conventions
- `dist/` and derived data are gitignored and disposable; never commit build outputs. This repo is public: keep tokens, `.env` contents, and private keys out of commits and out of this file.
