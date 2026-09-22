#!/bin/bash
#
# Install the tunnel agent.
#
# The agent is a small privileged helper. The app starts it once, through the
# system's normal elevation prompt, and it then stays alive for the lifetime of
# the tunnel. Ending the tunnel later is a word on a pipe to a process that is
# already root, so it needs no second prompt, no warm sudo timestamp and no
# stored password.
#
# It lives here, and not inside the app bundle, on purpose. The app execs this
# file as root; if it lived somewhere the user can write, then replacing it
# would turn the next connect's approval into a way to run arbitrary code as
# root. It is root-owned and mode 0755, and it is signed so that the app can
# tell it apart from anything else that ends up at that path.
#
# Usage: ./packaging/install-agent.sh [--uninstall] [--sign-only] [--dry-run] [--help]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TurtleDiver"              # only used to read the app's own signature
PRODUCT="TurtleDiverAgent"          # the SwiftPM executable target
INSTALL_DIR="/usr/local/libexec"    # TunnelAgent.installDirectory
INSTALL_NAME="turtlediver-agent"    # TunnelAgent.executableName
INSTALLED="$INSTALL_DIR/$INSTALL_NAME"
TEAM_ID="KT7QU923S8"

DO_UNINSTALL=0
DO_DRY_RUN=0
DO_SIGN_ONLY=0

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; }
ok()   { printf '%s  ✓ %s%s\n' "$GREEN" "$1" "$OFF"; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

usage() {
    cat <<EOF
${BOLD}Install the tunnel agent for TurtleDiver.${OFF}

Usage: ./packaging/install-agent.sh [options]

  --uninstall    Remove the installed agent
  --sign-only    Build and sign the agent, install nothing
  --dry-run      Show what would be done, change nothing
  --help         This message

The agent is installed to $INSTALLED, owned by root, mode 0755.
TurtleDiver works without it; without it, disconnecting can prompt.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) DO_UNINSTALL=1; shift ;;
        --sign-only) DO_SIGN_ONLY=1; shift ;;
        --dry-run)   DO_DRY_RUN=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *)           die "unknown option $1 (try --help)" ;;
    esac
done

# A field out of a code signature. `codesign -d` writes all of this to stderr.
signature_field() {
    codesign -dv --verbose=2 "$1" 2>&1 | sed -n "s/^$2=//p" | head -1
}

all_identities() {
    # The trailing "N valid identities found" line is not an identity.
    security find-identity -v -p codesigning 2>/dev/null \
        | grep '"' | sed -E 's/^[^"]*"([^"]*)".*$/\1/'
}

if [ "$DO_UNINSTALL" = 1 ]; then
    step "Removing the tunnel agent"
    if [ ! -e "$INSTALLED" ]; then
        ok "nothing installed at $INSTALLED"
        exit 0
    fi
    if [ "$DO_DRY_RUN" = 1 ]; then
        ok "would remove $INSTALLED"
        exit 0
    fi
    sudo rm -f "$INSTALLED" || die "could not remove $INSTALLED"
    ok "removed $INSTALLED"
    exit 0
fi

step "Building $PRODUCT"
cd "$ROOT" || die "cannot enter $ROOT"
command -v swift >/dev/null 2>&1 || die "swift not found — install Xcode from the App Store"
swift build -c release --product "$PRODUCT" >/dev/null || die "swift build failed — run 'swift build --product $PRODUCT' to see why"
BIN="$ROOT/.build/release/$PRODUCT"
[ -x "$BIN" ] || die "$BIN was not produced"
ok "$(basename "$BIN") $(du -h "$BIN" | cut -f1)"

# Signed with whatever signed the app, so that "signed by us" means the same
# thing for both files, and so that the app can tell this file apart from
# anything else that ends up at the same path.
#
# Which certificate that is cannot be guessed from its name. This machine has an
# "Apple Development" identity belonging to a different team, and the app's own
# team identifier does not appear in any certificate's display name at all —
# it is not the string in brackets. So the identity is chosen by signing and
# reading the result back: the first candidate that produces a signature the app
# would accept. Measured for this shape of certificate: a bare binary signed
# with the app's own certificate reports the same TeamIdentifier as the app.
APP_PATH_CANDIDATES="$ROOT/build/Build/Products/Release/$APP_NAME.app /Applications/$APP_NAME.app"
EXPECTED_TEAM="$TEAM_ID"
for candidate in $APP_PATH_CANDIDATES; do
    if [ -d "$candidate" ]; then
        app_team="$(signature_field "$candidate" TeamIdentifier)"
        if [ -n "$app_team" ]; then
            EXPECTED_TEAM="$app_team"
            ok "the app at $candidate is signed for team $EXPECTED_TEAM"
            break
        fi
    fi
done

step "Signing"
if [ "$DO_DRY_RUN" = 1 ]; then
    ok "would try $(all_identities | wc -l | tr -d ' ') identities until one signs for team $EXPECTED_TEAM"
    exit 0
fi

candidates="${TURTLE_AGENT_SIGN_IDENTITY:-}"$'\n'"$(all_identities)"
SIGNED_WITH=""
# An identity's name contains spaces, so this reads whole lines. It is a here
# string rather than a pipe on purpose: a pipe would run the loop in a subshell
# and SIGNED_WITH would be thrown away with it.
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    codesign --force --options runtime --sign "$candidate" --identifier "$INSTALL_NAME" "$BIN" >/dev/null 2>&1 || continue
    agent_team="$(signature_field "$BIN" TeamIdentifier)"
    if [ "$agent_team" = "$EXPECTED_TEAM" ]; then
        SIGNED_WITH="$candidate"
        break
    fi
done <<<"$candidates"
[ -n "$SIGNED_WITH" ] || die "none of the code-signing identities in this keychain
       produces a signature for team $EXPECTED_TEAM, which is the team the app
       is signed for. The app checks the agent against its own signature before
       starting it, so an agent signed by anyone else would not be used.
       Install a certificate for this team, or set TURTLE_AGENT_SIGN_IDENTITY."
codesign --verify --strict "$BIN" >/dev/null 2>&1 || die "the agent does not verify after signing"
# The app checks that the file at the installed path is signed *as the agent*,
# and "as the agent" is the installed name. Left to itself, `codesign` names the
# signature after the build product — `TurtleDiverAgent` — and the app would
# refuse the agent it had just installed. Measured: that is what it does.
agent_id="$(signature_field "$BIN" Identifier)"
[ "$agent_id" = "$INSTALL_NAME" ] || die "the agent is signed as '${agent_id:-nothing}', not $INSTALL_NAME"
ok "signed by $SIGNED_WITH, team $EXPECTED_TEAM"
[ "$DO_SIGN_ONLY" = 1 ] && { ok "$BIN"; exit 0; }

step "Installing to $INSTALLED"
if [ "$DO_DRY_RUN" = 1 ]; then
    ok "would install $BIN -> $INSTALLED (root:wheel 0755)"
    exit 0
fi

printf '  (you will be asked for your administrator password)\n'
sudo install -d -o root -g wheel -m 0755 "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
# Through a temporary name in the same directory, so a failure part-way cannot
# leave a truncated binary where the app expects a working one.
sudo install -o root -g wheel -m 0755 "$BIN" "$INSTALL_DIR/.$INSTALL_NAME.new" || die "could not stage the agent"
sudo mv -f "$INSTALL_DIR/.$INSTALL_NAME.new" "$INSTALLED" || die "could not place the agent"
ok "$INSTALLED"

step "Verifying what was installed"
OWNER="$(stat -f '%Su:%Sg %Sp' "$INSTALLED" 2>/dev/null)"
case "$OWNER" in
    "root:wheel -rwxr-xr-x") ok "owner and mode: $OWNER" ;;
    *) die "unexpected owner or mode: $OWNER (expected root:wheel -rwxr-xr-x)" ;;
esac
codesign --verify --strict "$INSTALLED" >/dev/null 2>&1 || die "the installed agent does not verify"
INSTALLED_TEAM="$(signature_field "$INSTALLED" TeamIdentifier)"
[ "$INSTALLED_TEAM" = "$EXPECTED_TEAM" ] || die "installed agent has team '${INSTALLED_TEAM:-none}', expected $EXPECTED_TEAM"
INSTALLED_ID="$(signature_field "$INSTALLED" Identifier)"
[ "$INSTALLED_ID" = "$INSTALL_NAME" ] || die "the installed agent is signed as '${INSTALLED_ID:-nothing}', not $INSTALL_NAME"
ok "signed as $INSTALLED_ID, team $INSTALLED_TEAM"

printf '\n%sDone.%s TurtleDiver will use the agent on its next connection.\n' "$GREEN" "$OFF"
printf 'Remove it again with: ./packaging/install-agent.sh --uninstall\n'
