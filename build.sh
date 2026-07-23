#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
configuration="${1:-Debug}"

case "$configuration" in
  Debug|Release) ;;
  *)
    print -u2 'Usage: ./build.sh [Debug|Release]'
    exit 2
    ;;
esac

cd "$root"
xcodegen generate
xcodebuild \
  -project WhisperMLXUI.xcodeproj \
  -scheme WhisperMLXUI \
  -configuration "$configuration" \
  build \
  CODE_SIGNING_ALLOWED=NO

print "Build abgeschlossen: $configuration"
