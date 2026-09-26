#!/usr/bin/env bash
set -euo pipefail

APP=${1:-}
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 /path/to/MoRead.app" >&2
  exit 2
fi
PLIST="$APP/Info.plist"
test -f "$PLIST"
PB=/usr/libexec/PlistBuddy

read_plist() { "$PB" -c "Print :$1" "$PLIST" 2>/dev/null; }

EXECUTABLE=$(read_plist CFBundleExecutable)
test -n "$EXECUTABLE"
test -x "$APP/$EXECUTABLE"

BUNDLE_ID=$(read_plist CFBundleIdentifier)
[[ "$BUNDLE_ID" == "com.mozhi.reader.ios" ]]

MIN_IOS=$(read_plist MinimumOSVersion)
[[ "$MIN_IOS" == "17.0" ]]

# Universal iPhone + iPad build.
FAMILY=$(read_plist UIDeviceFamily)
grep -q '1' <<<"$FAMILY"
grep -q '2' <<<"$FAMILY"

# Background audiobook + WebDAV backup scheduling.
BACKGROUND=$(read_plist UIBackgroundModes)
grep -q 'audio' <<<"$BACKGROUND"
grep -q 'processing' <<<"$BACKGROUND"
TASKS=$(read_plist BGTaskSchedulerPermittedIdentifiers)
grep -q "${BUNDLE_ID}.refresh" <<<"$TASKS"
grep -q "${BUNDLE_ID}.processing" <<<"$TASKS"

# External-open document registrations.
DOCS=$(read_plist CFBundleDocumentTypes)
grep -q 'public.plain-text' <<<"$DOCS"
grep -q 'org.idpf.epub-container' <<<"$DOCS"
grep -q 'com.mozhi.mdx' <<<"$DOCS"
grep -q 'com.mozhi.mdd' <<<"$DOCS"

# Localizations must be bundled, not merely present in source.
test -f "$APP/zh-Hans.lproj/Localizable.strings"
test -f "$APP/en.lproj/Localizable.strings"

# App must include Swift package frameworks or statically linked functionality after build.
# We intentionally do not require a Frameworks/OpenCC.framework path because SPM may link it statically.

printf 'Verified app: %s\n' "$APP"
printf 'Bundle ID: %s | Minimum iOS: %s | Executable: %s\n' "$BUNDLE_ID" "$MIN_IOS" "$EXECUTABLE"
