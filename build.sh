#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
configuration="${1:-Release}"
# Keep Xcode's mutable build products outside iCloud-synchronised folders.
# File Provider attributes added there invalidate an otherwise valid signature.
derived_data_path="${WHISPERMLXUI_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/whispermlx-ui-derived-data}"
product_root="$root/dist/$configuration"
app_name="WhisperMLX UI.app"
derived_app_path="$derived_data_path/Build/Products/$configuration/$app_name"
final_app_path="$product_root/$app_name"

case "$configuration" in
  Debug|Release) ;;
  *)
    print -u2 'Usage: ./build.sh [Debug|Release]'
    exit 2
    ;;
esac

cd "$root"
xcodegen generate
mkdir -p "$product_root"
# Xcode may reuse an existing app bundle for incremental builds. Remove file
# provider metadata before its final CodeSign phase runs.
if [[ -d "$derived_app_path" ]]; then
  /usr/bin/xattr -cr "$derived_app_path"
fi
if [[ -d "$derived_data_path/SourcePackages" ]]; then
  /usr/bin/xattr -cr "$derived_data_path/SourcePackages"
fi
xcodebuild \
  -project WhisperMLXUI.xcodeproj \
  -scheme WhisperMLXUI \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data_path" \
  build

rm -rf "$final_app_path"
/usr/bin/ditto "$derived_app_path" "$final_app_path"
/usr/bin/xattr -cr "$final_app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$final_app_path"

print "Build abgeschlossen: $configuration"
print "App: $final_app_path"
