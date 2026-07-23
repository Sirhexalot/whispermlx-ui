#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
updates_dir="${1:-$root/dist/sparkle-updates}"
public_dir="${2:-$root/docs}"
default_archive="$root/dist/Release/WhisperMLX-UI-macOS.zip"
download_base_url="${SPARKLE_DOWNLOAD_BASE_URL:-}"

find_generate_appcast() {
  local candidate
  for candidate in \
    "$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    "$root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
  do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

find_sign_update() {
  local candidate
  for candidate in \
    "$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$root/.build/artifacts/sparkle/Sparkle/bin/sign_update"
  do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

generate_appcast="$(find_generate_appcast)" || {
  print -u2 "Could not find Sparkle's generate_appcast tool."
  print -u2 "Build the project once in Xcode or with ./build.sh so SwiftPM fetches Sparkle artifacts."
  exit 2
}

sign_update="$(find_sign_update)" || {
  print -u2 "Could not find Sparkle's sign_update tool."
  exit 2
}

mkdir -p "$updates_dir" "$public_dir"

if [[ ! -f "$updates_dir/WhisperMLX-UI-macOS.zip" && -f "$default_archive" ]]; then
  cp "$default_archive" "$updates_dir/WhisperMLX-UI-macOS.zip"
fi

[[ -f "$updates_dir/WhisperMLX-UI-macOS.zip" ]] || {
  print -u2 "No update archive found at $updates_dir/WhisperMLX-UI-macOS.zip"
  exit 3
}

"$generate_appcast" "$updates_dir"

if [[ -f "$updates_dir/appcast.xml" ]]; then
  for archive in "$updates_dir"/*; do
    [[ -f "$archive" ]] || continue
    case "${archive:t}" in
      *.zip|*.dmg|*.tar|*.tar.gz|*.tar.xz)
        signature="$("$sign_update" "$archive")"
        filename="${archive:t}"
        FILENAME="$filename" SIGNATURE="$signature" /usr/bin/perl -0pi -e '
          my $filename = $ENV{FILENAME};
          my $signature = $ENV{SIGNATURE};
          s#<enclosure url="([^"]*\Q$filename\E[^"]*)"[^>]*/>#<enclosure url="$1" $signature type="application/octet-stream"/>#g;
        ' "$updates_dir/appcast.xml"
        ;;
    esac
  done
  if [[ -n "$download_base_url" ]]; then
    escaped_base_url="${download_base_url%/}"
    /usr/bin/sed -E -i '' "s|url=\"([^\"]+)\"|url=\"$escaped_base_url/\\1\"|g" "$updates_dir/appcast.xml"
  fi
  cp "$updates_dir/appcast.xml" "$public_dir/appcast.xml"
fi

print "Sparkle appcast generated in: $updates_dir"
print "Published feed copied to: $public_dir/appcast.xml"
if [[ -n "$download_base_url" ]]; then
  print "Archive URLs rewritten to: $download_base_url"
fi
