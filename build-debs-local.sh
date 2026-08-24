#!/usr/bin/env bash
# Build local Theos packages for both supported jailbreak schemes.
#
# Usage:
#   ./build-debs-local.sh                 # rootless + roothide
#   ./build-debs-local.sh rootless        # one scheme
#   ./build-debs-local.sh roothide        # one scheme
#   ./build-debs-local.sh --skip-tests
#
# Override Theos locations when needed:
#   THEOS_ROOTLESS=/path/to/theos \
#   THEOS_ROOTHIDE=/path/to/theos-roothide \
#   ./build-debs-local.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

OUTPUT_DIR="$REPO_DIR/Outputs/DEBS"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eevee-debs.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

RUN_TESTS=1
SCHEMES=""

say() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./build-debs-local.sh [rootless|roothide] [--skip-tests]

With no scheme argument both packages are built:
  rootless -> Outputs/DEBS/*iphoneos-arm64.deb
  roothide -> Outputs/DEBS/*iphoneos-arm64e-roothide.deb

Environment overrides:
  THEOS_ROOTLESS  Theos directory for the rootless build
  THEOS_ROOTHIDE  Theos directory for the RootHide build
  MAKE            GNU make executable, if it is not auto-detected
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        rootless|roothide)
            case " $SCHEMES " in
                *" $1 "*) ;;
                *) SCHEMES="$SCHEMES $1" ;;
            esac
            shift
            ;;
        all)
            SCHEMES="rootless roothide"
            shift
            ;;
        --skip-tests)
            RUN_TESTS=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[ -n "$SCHEMES" ] || SCHEMES="rootless roothide"

# Non-login SSH shells often do not include Homebrew in PATH.
for brew_bin in /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$brew_bin" ]; then
        PATH="$brew_bin:$PATH"
    fi
done
export PATH

resolve_make() {
    if [ -n "${MAKE:-}" ]; then
        if command -v "$MAKE" >/dev/null 2>&1; then
            command -v "$MAKE"
        elif [ -x "$MAKE" ]; then
            printf '%s\n' "$MAKE"
        else
            die "MAKE does not point to an executable: $MAKE"
        fi
        return
    fi

    for candidate in \
        gmake \
        /opt/homebrew/opt/make/libexec/gnubin/make \
        /usr/local/opt/make/libexec/gnubin/make; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return
        fi
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    die "GNU make not found. Install Homebrew make or set MAKE=/path/to/gmake."
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

MAKE_CMD="$(resolve_make)"
for command_name in swiftc xcrun lipo dpkg-deb ldid; do
    require_cmd "$command_name"
done

THEOS_ROOTLESS="${THEOS_ROOTLESS:-$HOME/theos}"
THEOS_ROOTHIDE="${THEOS_ROOTHIDE:-$HOME/theos-roothide}"

test_swift_file() {
    local source_file="$1"
    local test_file="$2"
    local output_file="$TMP_DIR/$(basename "$test_file" .swift)-test"

    swiftc "$source_file" "$test_file" -o "$output_file"
    "$output_file"
}

run_tests() {
    [ "$RUN_TESTS" -eq 1 ] || {
        warn "Skipping focused Swift tests (--skip-tests)."
        return
    }

    say "Running focused Swift tests"
    test_swift_file Sources/EeveeSpotify/Premium/Helpers/BrowsitaSectionStripper.swift Tests/BrowsitaSectionStripper/main.swift
    test_swift_file Sources/EeveeSpotify/Shared/Models/Extensions/URL+Extension.swift Tests/URLAdClassification/main.swift
    test_swift_file Sources/EeveeSpotify/Premium/Helpers/ServerSidedFeaturePolicy.swift Tests/ServerSidedFeaturePolicy/main.swift
    test_swift_file Sources/EeveeSpotify/Premium/Helpers/BundledConfigurationPolicy.swift Tests/BundledConfigurationPolicy/main.swift
    test_swift_file Sources/EeveeSpotify/Shared/Helpers/SyntheticLyricsTaskTracker.swift Tests/SyntheticLyricsTaskTracker/main.swift
    python3 Tests/ResolveConfigurationSnapshot/test.py
}

validate_deb() {
    local scheme="$1"
    local deb_file="$2"
    local expected_architecture="$3"
    local extract_dir="$TMP_DIR/extract-$scheme"
    local actual_architecture

    say "$scheme: validating $(basename "$deb_file")"
    dpkg-deb --info "$deb_file" >/dev/null
    dpkg-deb --contents "$deb_file" >/dev/null

    actual_architecture="$(dpkg-deb -f "$deb_file" Architecture)"
    [ "$actual_architecture" = "$expected_architecture" ] || die \
        "$scheme package architecture is $actual_architecture, expected $expected_architecture"

    mkdir -p "$extract_dir"
    dpkg-deb -x "$deb_file" "$extract_dir"
    find "$extract_dir" -type f -name EeveeSpotify.dylib -print -quit | grep -q . || die \
        "$scheme package does not contain EeveeSpotify.dylib"
}

clean_build() {
    if "$MAKE_CMD" clean; then
        return
    fi

    # Finder can recreate .DS_Store files under .theos/obj while Theos is
    # removing it. Retry after removing only this generated object directory.
    warn "Theos clean hit a transient generated-directory error; retrying."
    /bin/rm -rf "$REPO_DIR/.theos/obj"
    "$MAKE_CMD" clean
}

build_scheme() {
    local scheme="$1"
    local theos_path="$2"
    local expected_architecture="$3"
    local deb_file
    local staged_file
    local package_base

    [ -d "$theos_path" ] || die "$scheme Theos directory not found: $theos_path"

    say "$scheme: using Theos $theos_path"
    export THEOS="$theos_path"
    export THEOS_PACKAGE_SCHEME="$scheme"

    say "$scheme: cleaning previous build objects"
    clean_build

    say "$scheme: building EeveeSwiftProtobuf.framework"
    "$MAKE_CMD" build-eeveeswiftprotobuf

    say "$scheme: building package"
    "$MAKE_CMD" package FINALPACKAGE=1

    deb_file="$(ls -t packages/*.deb 2>/dev/null | head -n 1)"
    [ -n "$deb_file" ] && [ -f "$deb_file" ] || die "$scheme .deb was not produced"
    validate_deb "$scheme" "$deb_file" "$expected_architecture"

    mkdir -p "$OUTPUT_DIR"
    package_base="$(basename "$deb_file" .deb)"
    if [ "$scheme" = "roothide" ]; then
        staged_file="$OUTPUT_DIR/${package_base}-roothide.deb"
    else
        staged_file="$OUTPUT_DIR/${package_base}.deb"
    fi
    cp -f "$deb_file" "$staged_file"
    say "$scheme: saved $staged_file"
}

run_tests

for scheme in $SCHEMES; do
    case "$scheme" in
        rootless)
            build_scheme rootless "$THEOS_ROOTLESS" iphoneos-arm64
            ;;
        roothide)
            build_scheme roothide "$THEOS_ROOTHIDE" iphoneos-arm64e
            ;;
        *)
            die "Unsupported scheme: $scheme"
            ;;
    esac
done

say "All requested builds completed"
find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.deb' -print -exec ls -lh {} \;
