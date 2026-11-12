#!/bin/bash
# Has Mozilla sign Tab Scout's Firefox extension, so that Firefox adds it for good; without a signature Firefox
# only loads it until it quits. The extension is submitted as self-distributed ("unlisted"): Mozilla checks and signs
# it, and it is not listed on addons.mozilla.org. The signed package is saved as
# Resources/FirefoxExtension.signed.xpi, which build.sh puts into the app.
#
# Needs Node.js, and API credentials of a free addons.mozilla.org account, from
# https://addons.mozilla.org/developers/addon/api/key/ :
#   WEB_EXT_API_KEY=user:12345:67 WEB_EXT_API_SECRET=... bash sign-firefox.sh
# Mozilla signs each version once, so raise "version" in Resources/FirefoxExtension/manifest.json, and
# FirefoxExtension.version in Sources/FirefoxLink.swift with it, before signing a changed extension.
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="$SOURCE_DIR/.build/firefox-signed"
fail() { printf 'sign-firefox: %s\n' "$1" >&2; exit 1; }
[[ -n "${WEB_EXT_API_KEY:-}" && -n "${WEB_EXT_API_SECRET:-}" ]] || fail "set WEB_EXT_API_KEY and WEB_EXT_API_SECRET (see the top of this script)"
command -v npx >/dev/null || fail "Node.js is needed for Mozilla's web-ext tool"
/bin/rm -rf "$ARTIFACTS_DIR"
npx --yes web-ext@8 sign --channel unlisted --source-dir "$SOURCE_DIR/Resources/FirefoxExtension" --artifacts-dir "$ARTIFACTS_DIR"
SIGNED="$(/usr/bin/find "$ARTIFACTS_DIR" -name '*.xpi' -print -quit)"
[[ -n "$SIGNED" ]] || fail "Mozilla returned no signed package; see the output above"
/bin/cp "$SIGNED" "$SOURCE_DIR/Resources/FirefoxExtension.signed.xpi"
printf 'Saved %s\nRun deploy.sh to put it into Tab Scout.\n' "$SOURCE_DIR/Resources/FirefoxExtension.signed.xpi"
