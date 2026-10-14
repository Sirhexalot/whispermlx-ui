#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
destination="$root/Resources/BundledDiarizationModel"
source="${1:-$HOME/.local/share/whispermlx-ui/pyannote/speaker-diarization-community-1}"
mkdir -p "$destination"
while read -r digest filename; do
  mkdir -p "$destination/${filename:h}"
  /bin/cp "$source/$filename" "$destination/$filename"
done < "$root/bundled-diarization.sha256"
(cd "$destination" && /usr/bin/shasum -a 256 --strict -c "$root/bundled-diarization.sha256")
