#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
candidate="$(command -v uv)"
[[ -n "$candidate" && -x "$candidate" ]] || { print -u2 'Install uv before preparing the app build.'; exit 1; }
/usr/bin/ditto "${candidate:A}" "$root/bin/uv"
chmod 755 "$root/bin/uv"
