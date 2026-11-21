#!/bin/sh
set -eu

expected='bda59474202b887190f59d25b7b42c714469efae71276072c12fa0a38de68792'
archive=${1:?usage: verify-release-archive.sh PATH/TO/funasr-llamacpp-macos-arm64.tar.gz}
actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || {
  echo "FunASR archive SHA-256 mismatch: expected $expected, got $actual" >&2
  exit 1
}
tar -tzf "$archive" | grep -qx './llama-funasr-paraformer' || {
  echo 'FunASR archive does not contain llama-funasr-paraformer' >&2
  exit 1
}
tar -tzf "$archive" | grep -qx './llama-funasr-cli' || {
  echo 'FunASR archive does not contain llama-funasr-cli' >&2
  exit 1
}
printf '%s\n' "Verified FunASR runtime-llamacpp-v0.2.6 macOS arm64 archive"
