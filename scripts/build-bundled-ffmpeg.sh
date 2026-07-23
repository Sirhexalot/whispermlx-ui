#!/bin/zsh
set -euo pipefail

# Creates a portable Apple-Silicon FFmpeg for the macOS app bundle.  It uses
# FFmpeg's own codecs only, so the resulting executable has no Homebrew dylib
# dependency.  System frameworks are supplied by macOS.
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
version="8.1.2"
work_dir="${TMPDIR:-/tmp}/whispermlx-ui-ffmpeg-${version}"
archive="${work_dir}/ffmpeg-${version}.tar.xz"
source_dir="${work_dir}/ffmpeg-${version}"
output="${repo_root}/bin/ffmpeg"

mkdir -p "$work_dir"
if [[ ! -d "$source_dir" ]]; then
  curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-${version}.tar.xz" -o "$archive"
  tar -xJf "$archive" -C "$work_dir"
fi

cd "$source_dir"
./configure \
  --arch=arm64 \
  --target-os=darwin \
  --enable-static \
  --disable-shared \
  --disable-doc \
  --disable-debug \
  --disable-network \
  --disable-autodetect \
  --extra-ldflags="-framework AudioToolbox -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework AVFoundation -framework Foundation"
make -j"$(sysctl -n hw.ncpu)"

mkdir -p "${output:h}"
cp ffmpeg "$output"
chmod 755 "$output"
echo "Portable FFmpeg created: $output"
otool -L "$output"
