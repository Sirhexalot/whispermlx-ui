#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
target="$HOME/.local/bin"
app_target="/Applications/WhisperMLX UI.app"
mkdir -p "$target" "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui"
install -m 755 "$root/bin/whispermlx" "$target/whispermlx"
install -m 755 "$root/bin/whispermlx-ui" "$target/whispermlx-ui"
rm -f "$target/transkribiere" "$target/transkribiere-ui"
rm -rf "$app_target"
mkdir -p "$app_target/Contents/MacOS" "$app_target/Contents/Resources/bin"
install -m 755 "$root/bin/whispermlx-ui" "$app_target/Contents/MacOS/whispermlx-ui"
install -m 755 "$root/bin/whispermlx" "$app_target/Contents/Resources/bin/whispermlx"
install -m 644 "$root/app/Info.plist" "$app_target/Contents/Info.plist"
if [[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui/hf.env" ]]; then
  install -m 600 "$root/config/hf.env.example" "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui/hf.env"
fi
print 'Installed: whispermlx and whispermlx-ui'
print 'Installed app: /Applications/WhisperMLX UI.app'
print 'Add your Hugging Face token to ~/.config/whispermlx-ui/hf.env before enabling speaker diarization.'
