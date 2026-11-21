#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
archive="$stage_dir/vendor/funasr-llamacpp-macos-arm64.tar.gz"
destination=${1:?usage: package-paraformer-helper.sh APP/Contents/Helpers/llama-funasr-paraformer}

"$script_dir/verify-release-archive.sh" "$archive"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/funasr-package.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$tmp_dir" ./llama-funasr-paraformer
mkdir -p "$(dirname "$destination")"
install -m 755 "$tmp_dir/llama-funasr-paraformer" "$destination"

# Keep redistributors' required notices in the application bundle, alongside the
# binary, without embedding the (user-downloaded) model in the application.
contents_dir=$(CDPATH= cd -- "$(dirname "$destination")/.." && pwd)
mkdir -p "$contents_dir/Resources/ThirdPartyNotices"
install -m 644 "$stage_dir/THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/ThirdPartyNotices/FunASR-Paraformer.txt"

# A copied executable is nested code; sign it when Xcode supplies an identity.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination"
fi
"$script_dir/verify-bundled-helper.sh" "$destination"
