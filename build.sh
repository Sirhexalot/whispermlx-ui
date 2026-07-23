#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
configuration="${1:-Release}"
derived_data_path="$root/build/DerivedData"
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
xcodebuild \
  -project WhisperMLXUI.xcodeproj \
  -scheme WhisperMLXUI \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data_path" \
  build \
  CODE_SIGNING_ALLOWED=NO

rm -rf "$final_app_path"
cp -R "$derived_app_path" "$final_app_path"

print "Build abgeschlossen: $configuration"
print "App: $final_app_path"
