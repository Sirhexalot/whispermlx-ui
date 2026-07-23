#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
configuration="${1:-Release}"
app_name="WhisperMLX UI.app"
app_path="$root/dist/$configuration/$app_name"
archive_path="$root/dist/$configuration/WhisperMLX-UI-macOS.zip"

case "$configuration" in
  Debug|Release) ;;
  *)
    print -u2 'Usage: ./scripts/package-release.sh [Debug|Release]'
    exit 2
    ;;
esac

"$root/build.sh" "$configuration"

[[ -d "$app_path" ]] || {
  print -u2 "App bundle not found: $app_path"
  exit 3
}

rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

print "Archiv erstellt: $archive_path"
