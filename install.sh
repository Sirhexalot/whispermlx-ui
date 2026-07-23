#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
target="$HOME/.local/bin"
app_target="/Applications/WhisperMLX UI.app"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/whispermlx-ui"
runtime_python="$data_dir/venv/bin/python"
if [[ -n "${WHISPERMLX_PYTHON:-}" ]]; then
  bootstrap_python="$WHISPERMLX_PYTHON"
elif [[ -x "/opt/homebrew/opt/python@3.13/bin/python3.13" ]]; then
  bootstrap_python="/opt/homebrew/opt/python@3.13/bin/python3.13"
elif (( $+commands[python3.13] )); then
  bootstrap_python="${commands[python3.13]}"
else
  print -u2 'Python 3.13 is required. Install it with: brew install python@3.13'
  exit 1
fi
mkdir -p "$target" "$data_dir" "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui"
if [[ ! -x "$runtime_python" ]]; then
  "$bootstrap_python" -m venv "$data_dir/venv"
fi
"$runtime_python" -m pip install --quiet --upgrade pip whispermlx
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
print "Installed WhisperMLX runtime: $data_dir/venv"
print 'Add your Hugging Face token to ~/.config/whispermlx-ui/hf.env before enabling speaker diarization.'
