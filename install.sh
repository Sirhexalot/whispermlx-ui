#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
target="$HOME/.local/bin"
mkdir -p "$target" "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui"
install -m 755 "$root/bin/transkribiere" "$target/transkribiere"
install -m 755 "$root/bin/transkribiere-ui" "$target/transkribiere-ui"
if [[ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui/hf.env" ]]; then
  install -m 600 "$root/config/hf.env.example" "${XDG_CONFIG_HOME:-$HOME/.config}/whispermlx-ui/hf.env"
fi
print 'Installed: transkribiere and transkribiere-ui'
print 'Add your Hugging Face token to ~/.config/whispermlx-ui/hf.env before enabling speaker diarization.'
