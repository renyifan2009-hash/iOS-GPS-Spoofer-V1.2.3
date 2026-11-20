#!/bin/bash
# Downloads idevice (https://github.com/jkcoxson/idevice, Rust, MIT), the
# library the iPhone-only mode uses to reach the iPhone's own developer
# services. Checks it against a pinned SHA-256 and unpacks it to
# iPhoneRemote/Vendor/IDevice.xcframework (not in git: about 1.3 GB unpacked).
#
#   iPhoneRemote/scripts/fetch-idevice.sh
#
# IDEVICE_ZIP=/path/to/idevice-xcframework-2dca9a58.zip uses a copy you already
# downloaded. IDEVICE_CACHE_DIR=<folder> keeps the download there for next
# time (CI caches that folder). Either way it's checked against the SHA-256.
set -euo pipefail

# idevice's master branch at 2dca9a58 (2026-11-16), built by its own CI (run 43892168504, the
# "idevice-xcframework" artifact), because no release has these fixes yet:
# - every RSD handshake presents the same host UUID (df53825a, e5645743). Since iOS 27.2 the
#   iPhone closes every developer service it advertised when a connection presents a new one,
#   which a reconnect (after loading developer support, or after the link drops) always did.
# - the TCP stack inside the tunnel: jktcp 0.1.8 and an MSS of 8192 (9c1ad299, edf25870), for
#   tunnels on iOS 27 that hung or dropped.
# Nothing the app calls changed signature; see docs/PHONE-ONLY.md. The zip is kept as a
# pre-release asset of this repository, since CI artifacts expire and need a GitHub login.
VERSION="0.1.68-2dca9a58"
SHA256="8473a34cbccd06b4955c5dd9808f01086deeeac0dfe8533060729ecdc62c6611"
URL="https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3/releases/download/idevice-2dca9a58/idevice-xcframework-2dca9a58.zip"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/Vendor"
FRAMEWORK="$DEST/IDevice.xcframework"
STAMP="$FRAMEWORK/.idevice-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ]; then
  echo "idevice $VERSION is already in Vendor/."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ZIP="${IDEVICE_ZIP:-}"
CACHED="${IDEVICE_CACHE_DIR:-}${IDEVICE_CACHE_DIR:+/idevice-xcframework-v${VERSION}.zip}"
if [ -z "$ZIP" ] && [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
  ZIP="$CACHED"
fi
if [ -z "$ZIP" ]; then
  echo "Downloading idevice $VERSION (about 210 MB)…"
  ZIP="${CACHED:-$WORK/idevice.zip}"
  mkdir -p "$(dirname "$ZIP")"
  curl -fL --retry 3 --progress-bar -o "$ZIP.part" "$URL"
  mv "$ZIP.part" "$ZIP"
fi

echo "$SHA256  $ZIP" | shasum -a 256 -c - >/dev/null || {
  echo "The download doesn't match the pinned SHA-256. Not using it." >&2
  # A bad copy in the cache would fail every run after this one.
  if [ "$ZIP" = "$CACHED" ]; then rm -f "$CACHED"; fi
  exit 1
}

unzip -q "$ZIP" -d "$WORK/unzipped"
FOUND="$(find "$WORK/unzipped" -maxdepth 3 -name IDevice.xcframework -type d | head -1)"
if [ -z "$FOUND" ]; then
  echo "IDevice.xcframework isn't in the download." >&2
  exit 1
fi

rm -rf "$FRAMEWORK"
mkdir -p "$DEST"
mv "$FOUND" "$FRAMEWORK"
echo "$VERSION" > "$STAMP"
echo "idevice $VERSION is ready in Vendor/IDevice.xcframework."
