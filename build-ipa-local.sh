#!/usr/bin/env bash
# Local IPA build — mirror of .github/workflows/main.yml. Produces an IPA
# you can sign with Sideloadly/AltStore/TrollStore.
#
# Pipeline:
#   1. Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source
#      (renamed module — see Tools/SwiftProtobufBuild/).
#   2. theos `make package FINALPACKAGE=1` — produces .deb with
#      EeveeSpotify.dylib + EeveeSpotify.bundle + framework.
#   3. Build zxPluginsInject.dylib — sideload compat shim (keychain redirect,
#      group containers, CloudKit stub). LC-injected via ipapatch in step 6.
#   4. cyan inject deb-contents (dylib + framework + bundle) into vanilla IPA.
#   5. ipapatch LC-inject zxPluginsInject into main exec + every appex.
#   6. Strip Watch.app if it survived cyan -du.
#   7. Add alternate app icons and CFBundleAlternateIcons to the final IPA.
#
# Requires: theos, cyan (pyzule-rw), ipapatch, dpkg, ldid, plutil.

set -euo pipefail

VANILLA_IPA="${1:-}"
[ -n "$VANILLA_IPA" ] && [ -f "$VANILLA_IPA" ] || {
    echo "usage: $0 <path/to/Spotify-vanilla.ipa>" >&2
    exit 1
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

[ -n "${THEOS:-}" ] || { [ -d "$HOME/theos" ] && export THEOS="$HOME/theos" || { echo "THEOS not set"; exit 1; }; }

VERSION=$(grep -E '^Version:' control | awk '{print $2}')
SPOT_VERSION=$(unzip -p "$VANILLA_IPA" 'Payload/Spotify.app/Info.plist' | plutil -extract CFBundleShortVersionString raw - 2>/dev/null || echo "unknown")
OUT_DIR="Outputs/IPAS"
DEBUG_SUFFIX=""
if [ "${EEVEE_DEBUG:-0}" = "1" ]; then
    DEBUG_SUFFIX="-debug"
fi
OUT_IPA="$OUT_DIR/EeveeSpotify-${VERSION}-${SPOT_VERSION}${DEBUG_SUFFIX}.ipa"
mkdir -p "$OUT_DIR"

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

color "1/7  EeveeSwiftProtobuf.framework"
chmod +x Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh

color "2/7  theos make package (debug=${EEVEE_DEBUG:-0})"
THEOS_PACKAGE_SCHEME=rootless make package FINALPACKAGE=1 EEVEE_DEBUG="${EEVEE_DEBUG:-0}"
DEB_FILE=$(ls -t packages/com.eevee.spotify_*.deb 2>/dev/null | head -1)
[ -n "$DEB_FILE" ] || { echo "deb not produced"; exit 1; }

color "3/7  zxPluginsInject.dylib"
chmod +x Tools/build-zxpi.sh
Tools/build-zxpi.sh >/dev/null

color "4/7  extract deb"
DEB_EXTRACT="$REPO_DIR/Outputs/deb-extract"
rm -rf "$DEB_EXTRACT"; mkdir -p "$DEB_EXTRACT"
dpkg-deb -R "$DEB_FILE" "$DEB_EXTRACT"
DYLIB_SRC=$(find "$DEB_EXTRACT" -name 'EeveeSpotify.dylib' | head -1)
BUNDLE_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSpotify.bundle' | head -1)
FRAMEWORK_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSwiftProtobuf.framework' | head -1)
[ -n "$DYLIB_SRC" ] || { echo "dylib not in deb"; exit 1; }

color "5/7  cyan inject"
INJECT=("$DYLIB_SRC")
[ -n "$FRAMEWORK_SRC" ] && INJECT+=("$FRAMEWORK_SRC")
[ -n "$BUNDLE_SRC" ]    && INJECT+=("$BUNDLE_SRC")
rm -f "$OUT_IPA"
cyan -i "$VANILLA_IPA" -o "$OUT_IPA" -f "${INJECT[@]}" -c 9 -m 15.0 -du

color "6/7  ipapatch LC-inject zxPluginsInject"
ipapatch --input "$OUT_IPA" --inplace --noconfirm --dylib packages/zxPluginsInject.dylib

# Belt-and-suspenders: cyan -du normally strips Watch content, but recent
# Spotify IPAs use com.apple.WatchPlaceholder instead of Watch. Work in /tmp:
# Finder can recreate metadata inside Outputs/IPAS/Payload while `rm -rf` is
# walking it, which used to abort the build after an otherwise valid IPA was
# produced.
WATCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/eevee-watch.XXXXXX")"
unzip -q "$OUT_IPA" -d "$WATCH_TMP"
STRIPPED_WATCH=0
for WATCH_PATH in \
    "$WATCH_TMP/Payload/Spotify.app/Watch" \
    "$WATCH_TMP/Payload/Spotify.app/com.apple.WatchPlaceholder"; do
    if [ -e "$WATCH_PATH" ]; then
        rm -rf "$WATCH_PATH"
        STRIPPED_WATCH=1
    fi
done
if [ "$STRIPPED_WATCH" -eq 1 ]; then
    REBUILT_IPA="$WATCH_TMP/rebuilt.ipa"
    (cd "$WATCH_TMP" && zip -qry "$REBUILT_IPA" Payload)
    mv -f "$REBUILT_IPA" "$OUT_IPA"
fi
rm -rf "$WATCH_TMP"

color "7/7  alternate app icons"
chmod +x Tools/alt-icons.sh
Tools/alt-icons.sh "$OUT_IPA"

color "Done"
ls -lh "$OUT_IPA"
echo "Sign with Sideloadly / AltStore / TrollStore."
