#!/bin/bash
#
# Local development build. For shippable, signed, notarized artifacts use
# ./publish.sh instead.
#
# Usage: ./build.sh [--debug] [--install] [--test] [--no-clean] [--help]

set -uo pipefail

APP_NAME="TurtleDiver"
PROJECT_NAME="VPNConnect"
SCHEME="VPNConnect"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"

CONFIGURATION="Release"
DO_CLEAN=1
DO_INSTALL=0
DO_TEST=0

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; }
ok()   { printf '%s  ✓ %s%s\n' "$GREEN" "$1" "$OFF"; }
warn() { printf '%s  ! %s%s\n' "$YELLOW" "$1" "$OFF"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}Build TurtleDiver for this machine.${OFF}

Usage: ./build.sh [options]

  --debug        Build the Debug configuration instead of Release
  --install      Copy the build to /Applications and relaunch the app
  --test         Run the SwiftPM test suite first
  --no-clean     Reuse build/ (much faster; use it when only Swift changed)
  -h, --help     This text

The app is built at build/Build/Products/$CONFIGURATION/$APP_NAME.app.
Installing over a running copy: quit the app first — it restores the system
proxy on quit, and killing it would leave the proxy pointing at a dead engine.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)     CONFIGURATION="Debug"; shift ;;
        --install)   DO_INSTALL=1; shift ;;
        --test)      DO_TEST=1; shift ;;
        --no-clean)  DO_CLEAN=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1 (try --help)" ;;
    esac
done

APP_PATH="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found — install Xcode from the App Store"

# The three tools the app shells out to, resolved the same way
# VPNManager.binaryPath does, so this report and the app agree.
step "Runtime dependencies"
missing=0
for tool in openconnect stoken vpn-slice; do
    found=""
    for dir in /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/bin /bin; do
        if [ -x "$dir/$tool" ]; then found="$dir/$tool"; break; fi
    done
    if [ -n "$found" ]; then
        ok "$tool — $found"
    else
        warn "$tool — not found (brew install $tool)"
        missing=$((missing + 1))
    fi
done
[ "$missing" -gt 0 ] && warn "$missing tool(s) missing: the app will build, but connecting will fail until they are installed"

if [ "$DO_TEST" = 1 ]; then
    step "Running tests"
    ( cd "$ROOT" && swift test ) || die "tests failed"
    ok "tests passed"
fi

if [ "$DO_CLEAN" = 1 ]; then
    step "Cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

step "Building $APP_NAME ($CONFIGURATION)"
xcodebuild -project "$ROOT/$PROJECT_NAME.xcodeproj" \
           -scheme "$SCHEME" \
           -configuration "$CONFIGURATION" \
           -derivedDataPath "$BUILD_DIR" \
           build || die "build failed"

[ -d "$APP_PATH" ] || die "build reported success but $APP_PATH is missing"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
ok "built $APP_NAME $VERSION ($BUILD_NUMBER)"
printf '    %s\n' "$APP_PATH"

if [ "$DO_INSTALL" = 1 ]; then
    step "Installing to /Applications"
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        # Quitting lets the app restore the user's system proxy. Killing it
        # would leave the proxy armed against a port nothing is listening on.
        osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1
        for _ in 1 2 3 4 5 6; do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 1
        done
    fi
    pgrep -x "$APP_NAME" >/dev/null 2>&1 \
        && die "$APP_NAME is still running — quit it and re-run, or the copy will be replaced underneath it"
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_PATH" "/Applications/$APP_NAME.app" || die "could not copy the app"
    open -a "/Applications/$APP_NAME.app"
    ok "installed and launched"
else
    printf '\n    Install it with:  ./build.sh --no-clean --install\n'
    printf '    Ship it with:     ./publish.sh\n'
fi
