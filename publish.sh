#!/bin/bash
#
# Build the shippable artifacts: a signed disk image and a signed installer
# package, both notarized and stapled so a downloaded copy opens without a
# Gatekeeper warning.
#
# This replaces a version that produced artifacts Gatekeeper rejected:
#   - `pkgbuild --root <the.app>` installed the app bundle's *contents*
#     scattered under /Applications/TurtleDiver.app instead of the bundle,
#   - the .pkg was signed with the string "Sign to Run Locally", which is not
#     an identity, and the failure was swallowed by `|| productbuild …` so an
#     unsigned package shipped silently,
#   - nothing was notarized or stapled, so `spctl` rejected both artifacts
#     ("source=no usable signature").
#
# Usage: ./publish.sh [options]        (./publish.sh --help)

set -uo pipefail

APP_NAME="TurtleDiver"
PROJECT_NAME="VPNConnect"
SCHEME="VPNConnect"
BUNDLE_ID="com.xvii.kurakura.vpn"
TEAM_ID="KT7QU923S8"
ORG="com.xvii.kurakura"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
PACKAGING_DIR="$ROOT/packaging"

MAKE_DMG=1
MAKE_PKG=1
DO_BUILD=1
DO_CLEAN=1
NOTARIZE=1
LOCAL_MODE=0
SIGN_ID=""
INSTALLER_ID=""
NOTARY_PROFILE="${TURTLEDIVER_NOTARY_PROFILE:-turtlediver-notary}"
OUTPUT_DIR=""

# ---------------------------------------------------------------- output ---

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""
fi

step()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; }
info()  { printf '    %s\n' "$1"; }
dim()   { printf '    %s%s%s\n' "$DIM" "$1" "$OFF"; }
warn()  { printf '%s  ! %s%s\n' "$YELLOW" "$1" "$OFF"; }
ok()    { printf '%s  ✓ %s%s\n' "$GREEN" "$1" "$OFF"; }
bad()   { printf '%s  ✗ %s%s\n' "$RED" "$1" "$OFF"; }
die()   { printf '\n%serror:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}Build, sign, notarize and staple TurtleDiver installers.${OFF}

Usage: ./publish.sh [options]

Signing
  --sign-identity NAME      Developer ID Application identity to sign with.
                            Default: the first one in the keychain.
  --installer-identity NAME Developer ID Installer identity for the .pkg.
                            Default: the first one in the keychain.
  --local                   Skip Developer ID: sign with the development
                            certificate and do not notarize. Produces
                            artifacts a recipient must right-click > Open.

Notarization
  --notary-profile NAME     notarytool keychain profile
                            (default: $NOTARY_PROFILE, or \$TURTLEDIVER_NOTARY_PROFILE)
  --no-notarize             Sign but do not submit. The artifacts will be
                            rejected by Gatekeeper on any other Mac.

What to build
  --dmg, --pkg              Build only one of the two (default: both)
  --no-build                Reuse the existing app in build/
  --no-clean                Do not wipe build/ first
  --output-dir DIR          Where artifacts go (default: dist/)
  -h, --help                This text

One-time notarization setup (see docs/DISTRIBUTION.md):

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
      --apple-id you@example.com --team-id $TEAM_ID
EOF
}

# ------------------------------------------------------------- arguments ---

while [ $# -gt 0 ]; do
    case "$1" in
        --sign-identity)      SIGN_ID="${2:-}"; shift 2 ;;
        --installer-identity) INSTALLER_ID="${2:-}"; shift 2 ;;
        --notary-profile)     NOTARY_PROFILE="${2:-}"; shift 2 ;;
        --output-dir)         OUTPUT_DIR="${2:-}"; shift 2 ;;
        --local)              LOCAL_MODE=1; NOTARIZE=0; shift ;;
        --no-notarize)        NOTARIZE=0; shift ;;
        --dmg)                MAKE_DMG=1; MAKE_PKG=0; shift ;;
        --pkg)                MAKE_PKG=1; MAKE_DMG=0; shift ;;
        --no-build)           DO_BUILD=0; shift ;;
        --no-clean)           DO_CLEAN=0; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "unknown option: $1 (try --help)" ;;
    esac
done

[ -n "$OUTPUT_DIR" ] && DIST_DIR="$OUTPUT_DIR"

# ------------------------------------------------------------- preflight ---

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found${2:+ — $2}"
}

step "Preflight"
need xcodebuild "install Xcode from the App Store"
need codesign
need hdiutil
need ditto
need shasum
[ "$MAKE_PKG" = 1 ] && need pkgbuild
[ "$MAKE_PKG" = 1 ] && need productbuild
if [ "$NOTARIZE" = 1 ]; then
    need xcrun
    xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found — Xcode 13 or newer is required"
    xcrun --find stapler    >/dev/null 2>&1 || die "stapler not found — Xcode 13 or newer is required"
fi
info "$(xcodebuild -version | head -1)"
info "bundle id $BUNDLE_ID, team $TEAM_ID"

# The identity has to be a leaf certificate ("Developer ID Application: Name
# (TEAMID)"), not the "Developer ID Certification Authority" intermediate that
# Xcode installs for everyone. find-identity lists leaves only.
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "\"$1" | head -1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/'
}

if [ -z "$SIGN_ID" ]; then
    if [ "$LOCAL_MODE" = 1 ]; then
        dim "local mode: the project's own signing settings decide the identity"
    else
        SIGN_ID="$(find_identity 'Developer ID Application')"
        [ -n "$SIGN_ID" ] || die "no 'Developer ID Application' identity in the keychain.
       Run with --local to build signed-for-this-machine artifacts, or create
       the certificate first — see docs/DISTRIBUTION.md."
    fi
fi
if [ "$MAKE_PKG" = 1 ] && [ -z "$INSTALLER_ID" ] && [ "$LOCAL_MODE" = 0 ]; then
    INSTALLER_ID="$(find_identity 'Developer ID Installer')"
    [ -n "$INSTALLER_ID" ] || die "no 'Developer ID Installer' identity in the keychain — see docs/DISTRIBUTION.md"
fi
[ -n "$SIGN_ID" ] && ok "application identity: $SIGN_ID"
[ "$MAKE_PKG" = 1 ] && info "installer identity:   ${INSTALLER_ID:-<none, unsigned>}"

if [ "$NOTARIZE" = 1 ]; then
    # A missing profile is a silent no-op at submit time, which is how an
    # un-notarized release gets published. Prove the credentials first.
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        die "notarytool profile '$NOTARY_PROFILE' is not usable.
       Store it once:
         xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id $TEAM_ID
       or pass --no-notarize to sign without submitting."
    fi
    ok "notarization credentials: profile '$NOTARY_PROFILE'"
fi

if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    warn "working tree is dirty — the artifacts will not match any commit"
fi

mkdir -p "$DIST_DIR"

# ----------------------------------------------------------------- build ---

if [ "$DO_BUILD" = 1 ]; then
    step "Building $APP_NAME (Release)"
    if [ "$DO_CLEAN" = 1 ]; then
        rm -rf "$BUILD_DIR"
    fi

    # Manual signing with an explicit identity in the release path: automatic
    # signing picks whatever Xcode last chose, which is a development
    # certificate even in a Release build. Hardened runtime comes from
    # ENABLE_HARDENED_RUNTIME in the project (required for notarization) and
    # --timestamp is required alongside it.
    if [ "$LOCAL_MODE" = 1 ]; then
        # Automatic: a development identity needs a team, not a profile, and
        # this is what build.sh already produces — the same signature means the
        # login-Keychain items the app stored stay readable across rebuilds.
        SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID")
    else
        SIGN_ARGS=(
            CODE_SIGN_STYLE=Manual
            CODE_SIGN_IDENTITY="$SIGN_ID"
            DEVELOPMENT_TEAM="$TEAM_ID"
            OTHER_CODE_SIGN_FLAGS="--timestamp"
        )
    fi

    xcodebuild -project "$ROOT/$PROJECT_NAME.xcodeproj" \
               -scheme "$SCHEME" \
               -configuration Release \
               -derivedDataPath "$BUILD_DIR" \
               "${SIGN_ARGS[@]}" \
               build || die "build failed"

    [ -d "$APP_PATH" ] || die "expected app not found at $APP_PATH"
    ok "built $APP_PATH"
else
    step "Reusing the existing build"
    [ -d "$APP_PATH" ] || die "no app at $APP_PATH — drop --no-build"
    ok "$APP_PATH"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist") \
    || die "cannot read CFBundleShortVersionString from the built app"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist") \
    || die "cannot read CFBundleVersion from the built app"
PLIST_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")

# The scripts name the bundle explicitly, so a rename that misses one of them
# would ship an installer whose pkg-ref matches nothing.
[ "$PLIST_BUNDLE_ID" = "$BUNDLE_ID" ] \
    || die "bundle id drift: the app is $PLIST_BUNDLE_ID but publish.sh says $BUNDLE_ID"
info "version $VERSION ($BUILD_NUMBER), bundle id $PLIST_BUNDLE_ID"

PROJECT_VERSION=$(grep -m1 -o 'MARKETING_VERSION = [^;]*' "$ROOT/$PROJECT_NAME.xcodeproj/project.pbxproj" | sed 's/.*= //')
[ "$PROJECT_VERSION" = "$VERSION" ] \
    || die "version drift: project.pbxproj says $PROJECT_VERSION, the built app says $VERSION"

# ---------------------------------------------------------- sign and check ---

# The leaf certificate that actually signed a bundle. `find-identity` lists the
# leaves too, but picking from that list can disagree with the app — Xcode's
# automatic signing and this script would then sign the app and the disk image
# with different certificates.
app_signer() {
    codesign -dv --verbose=2 "$1" 2>&1 | sed -n 's/^Authority=//p' \
        | grep -E '^(Apple Development|Developer ID Application)' | head -1
}

step "Verifying the signature"
codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1 | sed 's/^/    /' \
    || die "the app's signature does not verify"

SIG_DETAIL=$(codesign -dv --verbose=2 "$APP_PATH" 2>&1)
ACTUAL_SIGNER=$(app_signer "$APP_PATH")
[ -n "$ACTUAL_SIGNER" ] \
    || die "the app is not signed by an Apple Development or Developer ID certificate"
printf '%s\n' "$SIG_DETAIL" | grep -q 'flags=.*runtime' \
    || die "the app is not signed with the hardened runtime — notarization would be rejected"
printf '%s\n' "$SIG_DETAIL" | grep -q "^TeamIdentifier=$TEAM_ID" \
    || die "the app is signed by team $(printf '%s\n' "$SIG_DETAIL" | sed -n 's/^TeamIdentifier=//p'), not $TEAM_ID"

if [ "$LOCAL_MODE" = 1 ]; then
    # Sign the image with the certificate the app already carries, unless the
    # caller named one — in which case it has to be the same certificate, or
    # the image and the app it holds would be signed by different teams.
    if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "$ACTUAL_SIGNER" ]; then
        die "--sign-identity '$SIGN_ID' is not the certificate that signed the app
       ('$ACTUAL_SIGNER'). Rebuild with it, or drop the option."
    fi
    SIGN_ID="$ACTUAL_SIGNER"
    ok "hardened runtime, signed by $ACTUAL_SIGNER, team $TEAM_ID"
else
    case "$ACTUAL_SIGNER" in
        "Developer ID Application"*) ;;
        *) die "the app was signed by '$ACTUAL_SIGNER', not a Developer ID Application certificate" ;;
    esac
    [ "$ACTUAL_SIGNER" = "$SIGN_ID" ] \
        || die "the app was signed by '$ACTUAL_SIGNER' but publish.sh asked for '$SIGN_ID'"
    ok "hardened runtime, Developer ID and team $TEAM_ID all present"
fi

# -------------------------------------------------------- notarize the app ---
#
# The app is notarized first and stapled, then wrapped: a stapled app carries
# its ticket offline, so the first launch does not depend on reaching Apple.
# `stapler` cannot staple a zip, and notarytool cannot take a bare .app bundle.

WORK_DIR="$BUILD_DIR/publish"
DMG_PATH=""
PKG_PATH=""
mkdir -p "$WORK_DIR"

notarize() {
    local target="$1" label="$2" json
    step "Notarizing the $label"
    json="$WORK_DIR/notary-$(basename "$target").json"
    if ! xcrun notarytool submit "$target" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait --output-format json > "$json" 2>"$WORK_DIR/notary.err"; then
        cat "$WORK_DIR/notary.err" >&2
        grep -o '"message"[^,]*' "$json" 2>/dev/null >&2
        die "notarization of the $label failed (log: $json)"
    fi
    if ! grep -q '"status":"Accepted"' "$json"; then
        cat "$json" >&2
        die "notarization of the $label was not accepted (log: $json)"
    fi
    ok "notarization accepted"
    xcrun stapler staple "$target" | sed 's/^/    /' || die "could not staple the $label"
    xcrun stapler validate "$target" >/dev/null || die "the staple on the $label does not validate"
}

if [ "$NOTARIZE" = 1 ]; then
    step "Preparing the app for notarization"
    rm -f "$WORK_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_PATH" "$WORK_DIR/$APP_NAME.zip" || die "could not zip the app"
    ok "zipped for submission (notarytool cannot take a bare .app)"

    notarize "$WORK_DIR/$APP_NAME.zip" "app"
else
    step "Notarization skipped"
    if [ "$LOCAL_MODE" = 1 ]; then
        warn "artifacts are signed for local use only; a downloaded copy needs right-click > Open"
    else
        warn "artifacts will be rejected by Gatekeeper on any Mac but this one"
    fi
fi

# ---------------------------------------------------------------- the DMG ---

make_dmg() {
    local dmg="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    local stage="$WORK_DIR/dmg_stage"

    step "Creating the disk image"
    rm -rf "$stage"; mkdir -p "$stage"
    # ditto, not cp -R: it preserves the extended attributes and the resource
    # fork, so the signature inside the image still verifies.
    ditto "$APP_PATH" "$stage/$APP_NAME.app" || die "could not stage the app"
    ln -s /Applications "$stage/Applications"
    sed "s/@VERSION@/$VERSION/g" "$PACKAGING_DIR/README_INSTALL.txt" > "$stage/READ_ME_FIRST.txt"

    rm -f "$dmg"
    # `hdiutil create` is deprecated on macOS 26 and prints a warning; the
    # replacement does not exist on macOS 14/15, so try it and fall back.
    if diskutil image create from --help >/dev/null 2>&1; then
        if ! diskutil image create from --format UDZO --volumeName "$APP_NAME" \
                "$stage" "$dmg" > "$WORK_DIR/diskutil.log" 2>&1; then
            cat "$WORK_DIR/diskutil.log" >&2
            die "diskutil could not create the disk image"
        fi
    else
        hdiutil create -volname "$APP_NAME" \
                       -srcfolder "$stage" \
                       -ov -format UDZO \
                       "$dmg" >/dev/null || die "hdiutil could not create the disk image"
    fi
    ok "$dmg"

    if [ -n "$SIGN_ID" ]; then
        codesign --force --sign "$SIGN_ID" --timestamp "$dmg" || die "could not sign the disk image"
        ok "disk image signed"
    fi

    if [ "$NOTARIZE" = 1 ]; then
        notarize "$dmg" "disk image"
    fi
    DMG_PATH="$dmg"
}

# ---------------------------------------------------------------- the PKG ---

make_pkg() {
    local pkg="$DIST_DIR/$APP_NAME-$VERSION.pkg"
    local pkgroot="$WORK_DIR/pkgroot"
    local component="$WORK_DIR/$APP_NAME.component.pkg"
    local dist_xml="$WORK_DIR/distribution.xml"
    local resources="$WORK_DIR/resources"

    step "Creating the installer package"
    rm -rf "$pkgroot" "$resources"; mkdir -p "$pkgroot/Applications" "$resources"
    # The root is the directory that *contains* the app. The old script passed
    # the app itself, which installs the bundle's contents into
    # /Applications/TurtleDiver.app rather than the bundle.
    ditto "$APP_PATH" "$pkgroot/Applications/$APP_NAME.app" || die "could not stage the app"
    sed "s/@VERSION@/$VERSION/g" "$PACKAGING_DIR/README_INSTALL.txt" > "$resources/README_INSTALL.txt"

    rm -f "$component"
    PKG_SIGN_ARGS=()
    if [ -n "$INSTALLER_ID" ]; then
        PKG_SIGN_ARGS=(--sign "$INSTALLER_ID")
    fi
    # pkgbuild prints "write: Permission denied" while it stores a file's
    # extended attributes as AppleDouble *inside the payload*. The payload is
    # inspected in verify_pkg below, which is what proves nothing junky would
    # be installed; on failure the noise is shown.
    if ! pkgbuild --root "$pkgroot" \
                 --install-location "/" \
                 --identifier "$BUNDLE_ID" \
                 --version "$VERSION" \
                 --ownership recommended \
                 ${PKG_SIGN_ARGS[@]+"${PKG_SIGN_ARGS[@]}"} \
                 "$component" > "$WORK_DIR/pkgbuild.log" 2>&1; then
        cat "$WORK_DIR/pkgbuild.log" >&2
        die "pkgbuild failed"
    fi
    ok "component package built"

    sed -e "s/@APP_NAME@/$APP_NAME/g" \
        -e "s/@VERSION@/$VERSION/g" \
        -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
        -e "s/@ORG@/$ORG/g" \
        "$PACKAGING_DIR/distribution.xml.tmpl" > "$dist_xml"

    rm -f "$pkg"
    productbuild --distribution "$dist_xml" \
                 --resources "$resources" \
                 --package-path "$WORK_DIR" \
                 ${PKG_SIGN_ARGS[@]+"${PKG_SIGN_ARGS[@]}"} \
                 "$pkg" >/dev/null || die "productbuild failed"
    ok "$pkg"

    if [ "$NOTARIZE" = 1 ]; then
        notarize "$pkg" "installer package"
    fi
    PKG_PATH="$pkg"
}

[ "$MAKE_DMG" = 1 ] && make_dmg
[ "$MAKE_PKG" = 1 ] && make_pkg

# ------------------------------------------------------- verify artifacts ---
#
# Both artifacts are opened and inspected. The old script never looked inside
# what it had built, which is how a package that installs the app's *contents*
# instead of the app shipped without anyone noticing.

verify_dmg() {
    local mount="$WORK_DIR/dmg_mount" rc=0

    step "Verifying the disk image"
    rm -rf "$mount"; mkdir -p "$mount"
    hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$mount" >/dev/null 2>&1 \
        || die "could not mount $DMG_PATH"

    [ -d "$mount/$APP_NAME.app" ] \
        || { bad "the image does not contain $APP_NAME.app"; rc=1; }
    [ -L "$mount/Applications" ] \
        || { bad "the image has no Applications symlink to drag the app onto"; rc=1; }
    if find "$mount" -name '._*' | grep -q .; then
        bad "the image carries AppleDouble junk files"; rc=1
    fi
    if [ -d "$mount/$APP_NAME.app" ]; then
        if codesign --verify --deep --strict "$mount/$APP_NAME.app" >/dev/null 2>&1; then
            ok "the app verifies inside the image"
        else
            bad "the app inside the image does not verify — the copy was damaged"; rc=1
        fi
    fi

    hdiutil detach "$mount" >/dev/null 2>&1
    rm -rf "$mount"
    [ "$rc" = 0 ] || die "the disk image did not pass verification"
}

verify_pkg() {
    local expand="$WORK_DIR/pkg_expand" rc=0 payload

    step "Verifying the installer package"
    rm -rf "$expand"
    pkgutil --expand-full "$PKG_PATH" "$expand" >/dev/null 2>&1 \
        || die "could not expand $PKG_PATH for inspection"

    # A product archive nests the component package inside it, so the payload
    # sits at <component>.pkg/Payload/... rather than Payload/... .
    payload=$(find "$expand" -maxdepth 6 -type d -name "$APP_NAME.app" 2>/dev/null | head -1)
    if [ -d "$payload" ] && [ "$(dirname "$payload")" = "$(find "$expand" -maxdepth 5 -type d -name Applications | head -1)" ]; then
        ok "installs to /Applications/$APP_NAME.app"
    else
        bad "installing this package would not put $APP_NAME.app in /Applications (found: ${payload:-nothing})"
        rc=1
    fi
    if find "$expand" -name '._*' | grep -q .; then
        bad "AppleDouble junk files would be installed"; rc=1
    fi
    if [ -d "$payload" ]; then
        if codesign --verify --deep --strict "$payload" >/dev/null 2>&1; then
            ok "the app verifies after unpacking"
        else
            bad "the packaged app does not verify — the package damaged it"; rc=1
        fi
    fi

    rm -rf "$expand"
    [ "$rc" = 0 ] || die "the installer package did not pass verification"
}

[ -n "$DMG_PATH" ] && verify_dmg
[ -n "$PKG_PATH" ] && verify_pkg

# ----------------------------------------------------------------- report ---

step "Checksums"
SUMS="$DIST_DIR/$APP_NAME-$VERSION.sha256"
SUM_ARGS=()
[ -n "$DMG_PATH" ] && SUM_ARGS+=("$(basename "$DMG_PATH")")
[ -n "$PKG_PATH" ] && SUM_ARGS+=("$(basename "$PKG_PATH")")
(
    cd "$DIST_DIR" || exit 1
    shasum -a 256 ${SUM_ARGS[@]+"${SUM_ARGS[@]}"} > "$(basename "$SUMS")"
) || die "could not write checksums"
ok "$SUMS"

step "Gatekeeper assessment"
assess() {
    local path="$1" kind="$2" out rc=0
    [ -n "$path" ] || return 0
    case "$kind" in
        dmg) out=$(spctl -a -vvv -t open --context context:primary-signature "$path" 2>&1); rc=$? ;;
        pkg) out=$(spctl -a -vvv -t install "$path" 2>&1); rc=$? ;;
        *)   out=$(spctl -a -vvv -t exec "$path" 2>&1); rc=$? ;;
    esac
    if [ "$rc" = 0 ]; then
        ok "$(basename "$path"): $(printf '%s\n' "$out" | head -1)"
    else
        bad "$(basename "$path"): $(printf '%s\n' "$out" | head -1)"
        dim "$(printf '%s\n' "$out" | sed -n '2p')"
    fi
}

assess "$APP_PATH" app
[ "$MAKE_DMG" = 1 ] && assess "$DMG_PATH" dmg
[ "$MAKE_PKG" = 1 ] && assess "$PKG_PATH" pkg

step "Done"
[ -n "$DMG_PATH" ] && info "$DMG_PATH"
[ -n "$PKG_PATH" ] && info "$PKG_PATH"
if [ "$NOTARIZE" = 0 ]; then
    warn "not notarized — recipients must right-click > Open, or use a notarized build"
fi
