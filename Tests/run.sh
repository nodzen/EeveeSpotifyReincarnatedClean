#!/usr/bin/env bash
# Focused test suites. Used by both build-debs-local.sh and CI so the list
# lives in exactly one place.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eevee-tests.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# control is the source of truth for the version; the two places that still
# carry it by hand must not drift away from it.
CONTROL_VERSION="$(sed -n 's/^Version:[[:space:]]*//p' control)"
if [ -z "$CONTROL_VERSION" ]; then
    echo "FAIL: control has no Version: line" >&2
    exit 1
fi
if ! grep -Fq "**Release:** \`$CONTROL_VERSION\`" README.md; then
    echo "FAIL: README release badge does not say $CONTROL_VERSION" >&2
    exit 1
fi
if ! grep -Fq "default: \"v$CONTROL_VERSION\"" .github/workflows/builddeb.yml; then
    echo "FAIL: builddeb.yml tag default is not v$CONTROL_VERSION" >&2
    exit 1
fi

compile_and_run() {
    local name="$1"
    shift
    swiftc "$@" -o "$TMP_DIR/$name"
    "$TMP_DIR/$name"
}

compile_and_run browsita-section-stripper \
    Sources/EeveeSpotify/Premium/Helpers/BrowsitaSectionStripper.swift \
    Tests/BrowsitaSectionStripper/main.swift

compile_and_run scrollsita-lyrics-card-patcher \
    Sources/EeveeSpotify/Lyrics/ScrollsitaLyricsCardPatcher.swift \
    Tests/ScrollsitaLyricsCardPatcher/main.swift

compile_and_run url-ad-classification \
    Sources/EeveeSpotify/Shared/Models/Extensions/URL+Extension.swift \
    Tests/URLAdClassification/main.swift

compile_and_run server-sided-feature-policy \
    Sources/EeveeSpotify/Premium/Helpers/ServerSidedFeaturePolicy.swift \
    Tests/ServerSidedFeaturePolicy/main.swift

compile_and_run bundled-configuration-policy \
    Sources/EeveeSpotify/Premium/Helpers/BundledConfigurationPolicy.swift \
    Tests/BundledConfigurationPolicy/main.swift

compile_and_run synthetic-lyrics-task-tracker \
    Sources/EeveeSpotify/Shared/Helpers/SyntheticLyricsTaskTracker.swift \
    Tests/SyntheticLyricsTaskTracker/main.swift

compile_and_run lyrics-response-gate \
    Sources/EeveeSpotify/Shared/Helpers/LyricsResponseGate.swift \
    Tests/LyricsResponseGate/main.swift

compile_and_run lyrics-dto \
    Sources/EeveeSpotify/Lyrics/Models/LyricsDto.swift \
    Sources/EeveeSpotify/Lyrics/Models/LyricsLineDto.swift \
    Sources/EeveeSpotify/Lyrics/Models/LyricsTranslationDto.swift \
    Sources/EeveeSpotify/Lyrics/Models/LyricsRomanizationStatus.swift \
    Tests/LyricsDto/main.swift

python3 Tests/ResolveConfigurationSnapshot/test.py
