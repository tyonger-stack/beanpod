#!/bin/sh
set -eu

binary=${1:?usage: verify-bundled-helper.sh PATH/TO/FUNASR_HELPER}
[ -x "$binary" ] || { echo "missing executable: $binary" >&2; exit 1; }
lipo -info "$binary" | grep -q 'arm64' || { echo 'helper is not arm64' >&2; exit 1; }
otool -L "$binary" | tail -n +2 | awk '{ print $1 }' | while IFS= read -r dep; do
  case "$dep" in
    /System/Library/*|/usr/lib/*) ;;
    *) echo "non-system dynamic dependency: $dep" >&2; exit 1 ;;
  esac
done
printf '%s\n' "Verified self-contained arm64 FunASR helper: $binary"
