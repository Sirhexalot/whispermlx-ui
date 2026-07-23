#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
configuration="${1:-Release}"
app_name="WhisperMLX UI.app"
archive_path="$root/dist/$configuration/WhisperMLX-UI-macOS.zip"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/whispermlx-release.XXXXXX")"
app_path="$staging_root/$app_name"

cleanup() {
  rm -rf "$staging_root"
}
trap cleanup EXIT

: "${APPLE_DEVELOPER_IDENTITY:?Set APPLE_DEVELOPER_IDENTITY to your 'Developer ID Application: ...' certificate name.}"
: "${APPLE_NOTARY_PROFILE:?Set APPLE_NOTARY_PROFILE to a notarytool keychain profile name.}"

case "$configuration" in
  Release) ;;
  *)
    print -u2 'Usage: ./scripts/create-release.sh [Release]'
    exit 2
    ;;
esac

"$root/build.sh" "$configuration"

/usr/bin/ditto "$root/dist/$configuration/$app_name" "$app_path"
/usr/bin/xattr -cr "$app_path"

[[ -d "$app_path" ]] || {
  print -u2 "App bundle not found: $app_path"
  exit 3
}

sign_nested_binaries() {
  local path
  while IFS= read -r path; do
    /usr/bin/codesign \
      --force \
      --timestamp \
      --options runtime \
      --sign "$APPLE_DEVELOPER_IDENTITY" \
      "$path"
  done < <(
    /usr/bin/find "$app_path/Contents" -type f -perm -111 -print0 |
      while IFS= read -r -d '' candidate; do
        if /usr/bin/file "$candidate" | /usr/bin/grep -q 'Mach-O'; then
          print -r -- "$candidate"
        fi
      done
  )
}

/usr/bin/xattr -cr "$app_path"
sign_nested_binaries
/usr/bin/xattr -cr "$app_path"

/usr/bin/codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_DEVELOPER_IDENTITY" \
  "$app_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path" || true

rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

xcrun notarytool submit "$archive_path" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

print "Release archive created: $archive_path"
