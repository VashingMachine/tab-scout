#!/bin/bash
# Build Tab Scout, install it (by default to /Applications) and relaunch it. The build is signed
# with the installed copy's certificate where possible. A running copy elsewhere is moved to the
# Trash so only one installation remains. Pass --dry-run to only print the plan.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$SOURCE_DIR/.build/deploy"
STAGE_APP="$STATE_DIR/stage/Tab Scout.app"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

fail() { printf 'deploy: %s\n' "$1" >&2; exit 1; }
is_tab_scout() {
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == "local.tabscout.app" ]]
}

# The running installation, ignoring preview runs and builds inside this repository.
running_app() {
    /bin/ps -axo command= | /usr/bin/awk -v repo="$SOURCE_DIR/" '
        found == "" && (/\/Contents\/MacOS\/TabScout$/ || /\/Contents\/MacOS\/TabScout /) && !/--preview/ && index($0, repo) != 1 {
            found = $0; sub(/\/Contents\/MacOS\/TabScout.*/, "", found)
        }
        END { if (found != "") print found }'
}

INSTALL_APP="${TAB_SCOUT_INSTALL_APP:-}"
INSTALL_SOURCE="from TAB_SCOUT_INSTALL_APP"
if [[ -z "$INSTALL_APP" && -f "$STATE_DIR/install-path" ]]; then
    INSTALL_APP="$(<"$STATE_DIR/install-path")"
    INSTALL_SOURCE="last deploy"
fi
if [[ -z "$INSTALL_APP" ]]; then INSTALL_APP="/Applications/Tab Scout.app"; INSTALL_SOURCE="default"; fi
[[ "$INSTALL_APP" == /*.app ]] || fail "install path must be an absolute .app path: $INSTALL_APP"
[[ ! -e "$INSTALL_APP" ]] || is_tab_scout "$INSTALL_APP" || fail "refusing to replace $INSTALL_APP: it is not Tab Scout"

RETIRE_APP="$(running_app)"
if [[ -n "$RETIRE_APP" && ( "$RETIRE_APP" == "$INSTALL_APP" || ! -d "$RETIRE_APP" ) ]]; then RETIRE_APP=""; fi
[[ -z "$RETIRE_APP" ]] || is_tab_scout "$RETIRE_APP" || RETIRE_APP=""

# Permissions follow the signing certificate, so reuse the installed copy's when the keychain has it.
REFERENCE_APP="$INSTALL_APP"
[[ -e "$REFERENCE_APP" ]] || REFERENCE_APP="$RETIRE_APP"
IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
identity_hash() { /usr/bin/awk -v name="\"$1\"" 'index($0, name) { print $2; exit }' <<<"$IDENTITIES"; }
SIGN_IDENTITY="${TAB_SCOUT_SIGN_IDENTITY:-}"
SIGN_SOURCE="from TAB_SCOUT_SIGN_IDENTITY"
installed_cert=""
if [[ -z "$SIGN_IDENTITY" && -n "$REFERENCE_APP" && -e "$REFERENCE_APP" ]]; then
    installed_cert="$(/usr/bin/codesign -dvv "$REFERENCE_APP" 2>&1 | /usr/bin/awk '/^Authority=/ && !n++ { print substr($0, 11) }')"
    if [[ -n "$installed_cert" ]]; then
        SIGN_IDENTITY="$(identity_hash "$installed_cert")"
        SIGN_SOURCE="$installed_cert, same as the installed copy"
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(/usr/bin/awk '/"Apple Development: / { print $2; exit }' <<<"$IDENTITIES")"
    SIGN_SOURCE="first Apple Development certificate"
    [[ -n "$installed_cert" ]] && SIGN_SOURCE+="; WARNING: $installed_cert is not in the keychain"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
    SIGN_SOURCE="ad-hoc; macOS will ask for permissions again after every deploy"
fi

printf 'Install: %s (%s)\n' "$INSTALL_APP" "$INSTALL_SOURCE"
printf 'Signing: %s\n' "$SIGN_SOURCE"
[[ -z "$RETIRE_APP" ]] || printf 'Retire:  %s (moved to the Trash)\n' "$RETIRE_APP"
$DRY_RUN && exit 0

/bin/rm -rf "$STAGE_APP"
TAB_SCOUT_OUTPUT_DIR="$(dirname "$STAGE_APP")" TAB_SCOUT_SIGN_IDENTITY="$SIGN_IDENTITY" bash "$SOURCE_DIR/build.sh"

# Only one copy may run; a second instance quits itself at launch.
if /usr/bin/pgrep -x TabScout >/dev/null; then
    echo "Quitting running Tab Scout..."
    /usr/bin/pkill -x TabScout || true
    for _ in {1..50}; do /usr/bin/pgrep -x TabScout >/dev/null || break; sleep 0.1; done
    /usr/bin/pkill -KILL -x TabScout 2>/dev/null || true
fi

if [[ -n "$RETIRE_APP" ]]; then
    /bin/mv "$RETIRE_APP" "$HOME/.Trash/Tab Scout $(date '+%Y-%m-%d %H.%M.%S').app"
fi
/bin/mkdir -p "$(dirname "$INSTALL_APP")"
/bin/rm -rf "$INSTALL_APP"
/bin/mv "$STAGE_APP" "$INSTALL_APP"
/usr/bin/codesign --verify --strict "$INSTALL_APP"
printf '%s\n' "$INSTALL_APP" > "$STATE_DIR/install-path"
/usr/bin/open "$INSTALL_APP"
for _ in {1..50}; do /usr/bin/pgrep -x TabScout >/dev/null && break; sleep 0.1; done
/usr/bin/pgrep -x TabScout >/dev/null || fail "Tab Scout did not start; try: open \"$INSTALL_APP\""
printf 'Deployed %s to %s\n' "$(/usr/bin/plutil -extract TabScoutBuild raw "$INSTALL_APP/Contents/Info.plist")" "$INSTALL_APP"
cat <<'EOF'
macOS can silently stop honoring the keyboard permission after a rebuild, even with the switch still on.
If Cmd+T does nothing, open System Settings > Privacy & Security > Device Control and Data Access
(Accessibility before macOS 27), remove Tab Scout with the - button, add this copy, and relaunch it.
EOF
