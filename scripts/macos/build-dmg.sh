#!/bin/bash
#
# build-dmg.sh — direct-distribution pipeline for "Accessibility Mapper" (macOS).
#
#   archive -> Developer ID sign -> export -> styled drag-and-drop DMG
#           -> sign the DMG -> notarize + staple
#
# No third-party tooling. Uses only xcodebuild, codesign, hdiutil, osascript,
# SetFile and xcrun notarytool/stapler.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

PROJECT="$REPO_ROOT/Apple/AccessibilityMapper.xcodeproj"
SCHEME="AccessibilityMapper"
APP_NAME="AccessibilityMapper.app"
TEAM_ID="Z44257Z59V"

BUILD_DIR="$REPO_ROOT/Apple/build"
DIST_DIR="$BUILD_DIR/dist"
ARCHIVE_PATH="$DIST_DIR/AccessibilityMapper.xcarchive"
EXPORT_DIR="$DIST_DIR/export"
ARTWORK_DIR="$DIST_DIR/artwork"
STAGE_DIR="$DIST_DIR/stage"
LOG_DIR="$DIST_DIR/logs"
RW_DMG="$DIST_DIR/AccessibilityMapper-rw.dmg"

ARTWORK_SCRIPT="$SCRIPT_DIR/make-dmg-artwork.sh"
EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"
DSSTORE_TOOL="$SCRIPT_DIR/patch-dsstore.py"

# --- CANONICAL DMG LAYOUT (contract v3 — must match the artwork) -----------
#
# v3 moved every element up so that nothing is drawn below y = 480, leaving the
# bottom 40pt of the 520pt canvas as empty gradient. That dead strip is
# deliberate: it is a tab-bar buffer. On a Mac where AppKit's app-global switch
# NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow is 1, every
# Finder browser window gets a tab bar regardless of what this DMG's .DS_Store
# says, and that tab bar eats 40pt off the bottom of the content area. Under v2
# the footer hairline (y=484) and the URL (y=500) landed inside that clipped
# strip and vanished. With v3 the clipped strip contains nothing but gradient.
#
# So: do NOT "tidy up" the empty space by moving content back down or shrinking
# the canvas. Forcing ShowTabView=False in .DS_Store is still done and still
# correct — this reflow is the defence in depth for the machines where AppKit
# overrides it.
VOLUME_NAME="Accessibility Mapper"
WINDOW_W=660          # Finder *content area* width, points
WINDOW_H=520          # Finder *content area* height, points
WINDOW_X=200          # where the window opens on screen
WINDOW_Y=120
ICON_SIZE=128
APP_POS_X=165;  APP_POS_Y=166
LINK_POS_X=495; LINK_POS_Y=166
WEB_POS_X=330;  WEB_POS_Y=336
WEBLOC_NAME="Visit the Website.webloc"
WEBLOC_URL="https://www.twowheeljunction.com/products/accessibilitymapper"

# Finder's AppleScript `bounds` for a container window is {l, t, r, b} of the
# whole window, title bar included; the content area is what the background
# image has to line up with. Set this to the height of the title bar so the
# content area comes out at exactly WINDOW_H. macOS 11+ Finder windows without
# a toolbar have a 28pt title bar. If the background ever looks vertically
# offset by a couple of dozen points, this is the knob to turn (0 makes
# `bounds` the content rect directly, which is what some Finder builds do).
#
# 28 is the FULL chrome budget, and it only holds while the tab bar is off.
# Measured on macOS 27 by locking the background art against a screenshot: the
# title bar is exactly 28pt, and a visible tab bar adds a further 40pt, for 68pt
# of chrome. Those 40pt come straight off the bottom of the background — the
# footer rule and the URL simply vanish.
#
# Finder has no AppleScript property for the tab bar, so `patch-dsstore.py`
# forces ShowTabView off in the persisted .DS_Store and the verification step at
# the end of this script fails the build if it ever comes back True. Do NOT
# raise TITLE_BAR_H to "make room" for a tab bar: that would leave a 40pt dead
# strip for the majority of users, whose Finder has no tab bar at all.
TITLE_BAR_H=28

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLU" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
die()  { printf '\n%sERROR:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup — never leave a stuck /Volumes mount behind
# ---------------------------------------------------------------------------

MOUNT_DEV=""
MOUNT_POINT=""

cleanup() {
  local rc=$?
  if [[ -n "$MOUNT_DEV" ]]; then
    printf '\n    detaching %s ...\n' "$MOUNT_DEV" >&2
    sync || true
    hdiutil detach "$MOUNT_DEV" -quiet 2>/dev/null \
      || hdiutil detach "$MOUNT_DEV" -force -quiet 2>/dev/null \
      || warn "could not detach $MOUNT_DEV — try: hdiutil detach '$MOUNT_DEV' -force"
    MOUNT_DEV=""
  fi
  return $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'HELPTEXT'
build-dmg.sh — build a signed, notarized drag-and-drop DMG for Accessibility Mapper.

USAGE
    scripts/macos/build-dmg.sh [options]

OPTIONS
    --notary-profile <name>   notarytool keychain profile to notarize with.
                              Create one once with:
                                xcrun notarytool store-credentials <name> \
                                  --apple-id <you@example.com> \
                                  --team-id Z44257Z59V \
                                  --password <app-specific-password>

    --skip-notarize           Build and sign the DMG but do not notarize.

    --version <x.y.z>         Override the version used in the output filename.
                              Default: CFBundleShortVersionString read from the
                              exported app's Info.plist.

    --identity <name>         Codesigning identity. Default: the single
                              "Developer ID Application" identity found in the
                              keychain (errors if none or more than one).

    -h, --help                Show this help.

NOTARIZATION CREDENTIALS are picked up in this order:
    1. --notary-profile <name>
    2. $NOTARY_PROFILE
    3. $AC_API_KEY_ID + $AC_API_ISSUER_ID + $AC_API_KEY_PATH  (App Store Connect API key)
    If none are found the script still produces a signed DMG, warns loudly,
    and prints the commands to notarize it later.

OUTPUT
    Apple/build/dist/AccessibilityMapper-<version>.dmg
HELPTEXT
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

NOTARY_PROFILE_ARG=""
SKIP_NOTARIZE=0
VERSION_OVERRIDE=""
IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile) [[ $# -ge 2 ]] || die "--notary-profile needs a value"; NOTARY_PROFILE_ARG="$2"; shift 2 ;;
    --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
    --version)        [[ $# -ge 2 ]] || die "--version needs a value"; VERSION_OVERRIDE="$2"; shift 2 ;;
    --identity)       [[ $# -ge 2 ]] || die "--identity needs a value"; IDENTITY="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# 2. Preflight
# ---------------------------------------------------------------------------

step "Preflight"

[[ -d "$PROJECT" ]] || die "project not found: $PROJECT"
ok "project: $PROJECT"

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not on PATH — install Xcode and run xcode-select --switch"
xcodebuild -version >/dev/null 2>&1 \
  || die "xcodebuild is not usable. Check: xcode-select -p  (currently: $(xcode-select -p 2>/dev/null || echo none))"
ok "xcodebuild: $(xcodebuild -version | head -1) ($(xcode-select -p))"

if [[ -z "$IDENTITY" ]]; then
  # Discover the Developer ID Application identity dynamically.
  # (No mapfile/readarray — /bin/bash on macOS is 3.2.)
  ID_LIST="$(security find-identity -v -p codesigning 2>/dev/null \
             | grep 'Developer ID Application' \
             | sed -E 's/.*"(.*)".*/\1/')"
  ID_COUNT=0
  if [[ -n "$ID_LIST" ]]; then
    ID_COUNT="$(printf '%s\n' "$ID_LIST" | wc -l | tr -d ' ')"
  fi
  case "$ID_COUNT" in
    0) die $'no "Developer ID Application" identity in the keychain.\n       Download one from https://developer.apple.com/account/resources/certificates\n       then re-run, or pass --identity "<name>".' ;;
    1) IDENTITY="$ID_LIST" ;;
    *) printf '    candidates:\n' >&2; printf '%s\n' "$ID_LIST" | sed 's/^/      /' >&2
       die 'more than one "Developer ID Application" identity found — pick one with --identity "<name>"' ;;
  esac
else
  ID_LIST="$(security find-identity -v -p codesigning 2>/dev/null)"
  printf '%s\n' "$ID_LIST" | grep -qF "$IDENTITY" \
    || die "identity not found in keychain: $IDENTITY"
fi
ok "signing identity: $IDENTITY"

[[ -f "$EXPORT_OPTIONS" ]] || die "missing export options: $EXPORT_OPTIONS"
ok "export options: $EXPORT_OPTIONS"

if [[ ! -x "$ARTWORK_SCRIPT" ]]; then
  if [[ -f "$ARTWORK_SCRIPT" ]]; then
    die "artwork script is not executable: $ARTWORK_SCRIPT (fix: chmod +x '$ARTWORK_SCRIPT')"
  fi
  die $'missing artwork generator: '"$ARTWORK_SCRIPT"$'\n       It must produce <output-dir>/background.tiff and <output-dir>/VolumeIcon.icns.'
fi
ok "artwork generator: $ARTWORK_SCRIPT"

[[ -f "$DSSTORE_TOOL" ]] || die $'missing .DS_Store helper: '"$DSSTORE_TOOL"$'\n       It forces the Finder tab bar off, which AppleScript cannot do.'
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH — required by $DSSTORE_TOOL"
ok ".DS_Store helper: $DSSTORE_TOOL"

# Locate SetFile (Finder attribute flags). Non-fatal if absent.
SETFILE=""
for candidate in /usr/bin/SetFile "$(xcrun -f SetFile 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then SETFILE="$candidate"; break; fi
done
if [[ -n "$SETFILE" ]]; then ok "SetFile: $SETFILE"; else warn "SetFile not found — volume icon and hidden extension will be skipped"; fi

# Refuse to run if a stale volume of the same name is already mounted.
if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
  die "a volume is already mounted at /Volumes/$VOLUME_NAME. Eject it first: hdiutil detach '/Volumes/$VOLUME_NAME'"
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# 3. Archive
# ---------------------------------------------------------------------------

COMMON_ARCHIVE_ARGS=(
  archive
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -destination 'generic/platform=macOS'
  -archivePath "$ARCHIVE_PATH"
  -allowProvisioningUpdates
)

ARCHIVE_STYLE=""

do_archive() {
  # $1 = label, rest = extra build settings
  local label="$1"; shift
  local log="$LOG_DIR/archive-$label.log"
  info "trying $label signing (log: ${log#"$REPO_ROOT/"})"
  rm -rf "$ARCHIVE_PATH"
  if xcodebuild "${COMMON_ARCHIVE_ARGS[@]}" "$@" >"$log" 2>&1; then
    if [[ -d "$ARCHIVE_PATH/Products/Applications/$APP_NAME" ]]; then
      ARCHIVE_STYLE="$label"
      return 0
    fi
    warn "$label archive reported success but produced no $APP_NAME"
  fi
  grep -E '^(.*: )?error:' "$log" | sort -u | sed 's/^/      /' >&2 || true
  return 1
}

step "Archiving (Release)"

if do_archive manual \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Developer ID Application" \
      DEVELOPMENT_TEAM="$TEAM_ID" \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO; then
  :
elif do_archive automatic \
      CODE_SIGN_STYLE=Automatic \
      DEVELOPMENT_TEAM="$TEAM_ID"; then
  :
else
  die "archive failed with both manual and automatic signing — see $LOG_DIR/archive-*.log"
fi

ok "archived with $ARCHIVE_STYLE signing: ${ARCHIVE_PATH#"$REPO_ROOT/"}"

# ---------------------------------------------------------------------------
# 4. Export
# ---------------------------------------------------------------------------

step "Exporting Developer ID app"

# Xcode has spelled the macOS direct-distribution method both ways over time.
# Try the plist as checked in, then the alternate spelling.
try_export() {
  local plist="$1" label="$2"
  local log="$LOG_DIR/export-$label.log"
  info "trying method '$label' (log: ${log#"$REPO_ROOT/"})"
  rm -rf "$EXPORT_DIR"
  if xcodebuild -exportArchive \
       -archivePath "$ARCHIVE_PATH" \
       -exportPath "$EXPORT_DIR" \
       -exportOptionsPlist "$plist" \
       -allowProvisioningUpdates >"$log" 2>&1; then
    [[ -d "$EXPORT_DIR/$APP_NAME" ]] && return 0
    warn "export succeeded but $APP_NAME is missing"
  fi
  grep -E '^(.*: )?error:|Error Domain' "$log" | sort -u | sed 's/^/      /' >&2 || true
  return 1
}

PRIMARY_METHOD="$(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_OPTIONS" 2>/dev/null || echo developer-id)"
ALT_METHOD="developerID"
[[ "$PRIMARY_METHOD" == "developerID" ]] && ALT_METHOD="developer-id"

ALT_OPTIONS="$DIST_DIR/ExportOptions-alt.plist"
cp "$EXPORT_OPTIONS" "$ALT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :method $ALT_METHOD" "$ALT_OPTIONS" >/dev/null

EXPORT_METHOD=""
if try_export "$EXPORT_OPTIONS" "$PRIMARY_METHOD"; then
  EXPORT_METHOD="$PRIMARY_METHOD"
elif try_export "$ALT_OPTIONS" "$ALT_METHOD"; then
  EXPORT_METHOD="$ALT_METHOD"
else
  die "export failed with both '$PRIMARY_METHOD' and '$ALT_METHOD' — see $LOG_DIR/export-*.log"
fi

APP="$EXPORT_DIR/$APP_NAME"
ok "exported with method '$EXPORT_METHOD': ${APP#"$REPO_ROOT/"}"

# ---------------------------------------------------------------------------
# 5. Verify the exported app
# ---------------------------------------------------------------------------

step "Verifying exported app"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/      /' \
  || die "codesign --verify --deep --strict failed for $APP"
ok "codesign --verify --deep --strict passed"

SIGN_INFO="$(codesign -dvvv "$APP" 2>&1)"
printf '%s\n' "$SIGN_INFO" | grep -E '^(Identifier|TeamIdentifier|Authority|Timestamp|CodeDirectory)' | sed 's/^/      /'

printf '%s\n' "$SIGN_INFO" | grep -q 'Authority=Developer ID Application' \
  || die $'the exported app is NOT signed with a Developer ID Application certificate.\n'"$(printf '%s\n' "$SIGN_INFO" | grep '^Authority=' | sed 's/^/       /')"
ok "authority chain contains Developer ID Application"

printf '%s\n' "$SIGN_INFO" | grep -q 'flags=.*runtime' \
  || warn "hardened runtime flag not visible in codesign output — notarization will reject this"

ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
printf '%s\n' "$ENTS" | grep -q 'com.apple.security.app-sandbox' \
  || die "exported app is missing the app-sandbox entitlement"
ok "entitlements include app-sandbox"

# Version: read from the *built* app, not the pbxproj.
if [[ -n "$VERSION_OVERRIDE" ]]; then
  VERSION="$VERSION_OVERRIDE"
  info "version overridden: $VERSION"
else
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "$VERSION" ]] || die "could not read CFBundleShortVersionString from $APP/Contents/Info.plist"
fi
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
ok "version $VERSION (build $BUILD_NUM)"

FINAL_DMG="$DIST_DIR/AccessibilityMapper-$VERSION.dmg"

# ---------------------------------------------------------------------------
# 6. Artwork
# ---------------------------------------------------------------------------

step "Generating DMG artwork"

rm -rf "$ARTWORK_DIR"
mkdir -p "$ARTWORK_DIR"
"$ARTWORK_SCRIPT" "$ARTWORK_DIR" 2>&1 | sed 's/^/      /'

BACKGROUND="$ARTWORK_DIR/background.tiff"
VOLICON="$ARTWORK_DIR/VolumeIcon.icns"
[[ -f "$BACKGROUND" ]] || die "$ARTWORK_SCRIPT did not produce $BACKGROUND"
[[ -f "$VOLICON" ]]    || die "$ARTWORK_SCRIPT did not produce $VOLICON"
ok "background.tiff + VolumeIcon.icns"

# ---------------------------------------------------------------------------
# 7. Stage and build a read-write DMG
# ---------------------------------------------------------------------------

step "Staging DMG contents"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/.background"

ditto "$APP" "$STAGE_DIR/$APP_NAME"
ln -s /Applications "$STAGE_DIR/Applications"
cp "$BACKGROUND" "$STAGE_DIR/.background/background.tiff"
# NOTE: .VolumeIcon.icns is deliberately NOT staged. `hdiutil create -srcfolder`
# silently drops it from the resulting volume; it is copied onto the mounted
# read-write image instead (see below).

cat > "$STAGE_DIR/$WEBLOC_NAME" <<WEBLOC
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>$WEBLOC_URL</string>
</dict>
</plist>
WEBLOC
plutil -lint "$STAGE_DIR/$WEBLOC_NAME" >/dev/null || die "generated $WEBLOC_NAME is not a valid plist"
ok "staged app, Applications symlink, $WEBLOC_NAME, background"

step "Creating read-write DMG"

STAGE_MB="$(du -sm "$STAGE_DIR" | cut -f1)"
DMG_MB=$(( STAGE_MB + STAGE_MB / 2 + 80 ))   # 50% + 80 MB headroom
info "staged content ${STAGE_MB} MB, allocating ${DMG_MB} MB"

rm -f "$RW_DMG"
hdiutil create \
  -srcfolder "$STAGE_DIR" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${DMG_MB}m" \
  "$RW_DMG" >/dev/null
ok "${RW_DMG#"$REPO_ROOT/"}"

step "Mounting and styling"

# The first /dev/ line is the whole image device; detaching it detaches
# every partition, which is what cleanup() wants.
ATTACH_OUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
printf '%s\n' "$ATTACH_OUT" | sed 's/^/      /'
MOUNT_DEV="$(printf '%s\n' "$ATTACH_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

[[ -n "$MOUNT_DEV" ]] || die "could not determine the attached device for $RW_DMG"
[[ -d "$MOUNT_POINT" ]] || die "volume did not mount at $MOUNT_POINT (stale mount of the same name?)"
ok "mounted $MOUNT_DEV at $MOUNT_POINT"

# NOTE ON ORDERING (verified experimentally on macOS 27):
#   * `hdiutil create -srcfolder` silently drops a staged .VolumeIcon.icns, so
#     the icon has to be copied onto the mounted image.
#   * Finder's `update without registering applications` DELETES
#     .VolumeIcon.icns and clears the volume's custom-icon (C) flag.
#   * Finder addresses items by their real on-disk name, so hiding the .webloc
#     extension before styling would break `item "Visit the Website.webloc"`.
#   * Finder has no AppleScript property for the tab bar, so ShowTabView has to
#     be patched into .DS_Store afterwards — but only once the AppleScript has
#     closed the window, or Finder would flush its own copy back over it.
# Therefore: style first, then patch .DS_Store, then volume icon, then hidden
# extension.

# --- Finder styling -------------------------------------------------------
# AppleScript `bounds` is {left, top, right, bottom} of the whole window.
WIN_L=$WINDOW_X
WIN_T=$WINDOW_Y
WIN_R=$(( WINDOW_X + WINDOW_W ))
WIN_B=$(( WINDOW_Y + WINDOW_H + TITLE_BAR_H ))

STYLE_LOG="$LOG_DIR/finder-style.log"
STYLED=0

read -r -d '' STYLE_SCRIPT <<APPLESCRIPT || true
on run
	tell application "Finder"
		tell disk "$VOLUME_NAME"
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			try
				set statusbar visible of container window to false
			end try
			try
				set sidebar width of container window to 0
			end try
			set the bounds of container window to {$WIN_L, $WIN_T, $WIN_R, $WIN_B}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to $ICON_SIZE
			set text size of viewOptions to 12
			set background picture of viewOptions to file ".background:background.tiff"
			set position of item "$APP_NAME" to {$APP_POS_X, $APP_POS_Y}
			set position of item "Applications" to {$LINK_POS_X, $LINK_POS_Y}
			set position of item "$WEBLOC_NAME" to {$WEB_POS_X, $WEB_POS_Y}
			try
				set extension hidden of item "$WEBLOC_NAME" to true
			end try
			-- Do NOT close and reopen here: reopening gives the window Finder's
			-- default geometry, and the subsequent update would persist THAT
			-- instead of the bounds set above.
			update without registering applications
			delay 2
			-- Re-assert the bounds in case anything nudged them, then let
			-- Finder flush the .DS_Store before we close.
			set the bounds of container window to {$WIN_L, $WIN_T, $WIN_R, $WIN_B}
			delay 2
			set finalBounds to the bounds of container window
			close
			return "" & (item 3 of finalBounds) - (item 1 of finalBounds) & "x" & (item 4 of finalBounds) - (item 2 of finalBounds)
		end tell
	end tell
end run
APPLESCRIPT

info "applying Finder layout (${WINDOW_W}x${WINDOW_H} content, icon size $ICON_SIZE)"

# Finder can take a moment to notice a freshly attached volume; until it does,
# `disk "Accessibility Mapper"` raises -1728. Wait for it, then retry a few times.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if osascript -e "tell application \"Finder\" to exists disk \"$VOLUME_NAME\"" 2>/dev/null | grep -q true; then
    break
  fi
  sleep 1
done

STYLE_ATTEMPTS=3
for attempt in $(seq 1 $STYLE_ATTEMPTS); do
  if printf '%s\n' "$STYLE_SCRIPT" | osascript - >"$STYLE_LOG" 2>&1; then
    STYLED=1
    break
  fi
  if grep -q -- '-1728' "$STYLE_LOG" && (( attempt < STYLE_ATTEMPTS )); then
    warn "Finder does not see the volume yet (attempt $attempt/$STYLE_ATTEMPTS) — retrying"
    sleep 3
    continue
  fi
  break
done

if (( STYLED )); then
  ok "Finder layout applied (window frame $(cat "$STYLE_LOG"), content ${WINDOW_W}x${WINDOW_H})"
else
  STYLE_ERR="$(cat "$STYLE_LOG")"
  printf '%s\n' "$STYLE_ERR" | sed 's/^/      /' >&2
  case "$STYLE_ERR" in
    *-1743*|*"Not authorized to send Apple events"*|*-1712*|*"AppleEvent timed out"*)
      cat >&2 <<TCC

${C_RED}${C_BOLD}Finder automation was refused or timed out.${C_RESET}
The DMG can still be built, but it will have NO window layout, NO background
image and NO icon positions — it will look like a plain folder.

To fix: System Settings > Privacy & Security > Automation, and enable
"Finder" underneath the app that runs this script (Terminal, iTerm, Xcode,
Claude Code, or whichever shell host you used). If no entry appears, run
    osascript -e 'tell application "Finder" to get name of startup disk'
from that app once and approve the prompt, then re-run this script.
A pending, unanswered permission dialog shows up as error -1712 (timeout).

TCC
      die "Finder styling failed — refusing to ship an unstyled DMG. Fix Automation permission, or comment out this check if you really want a bare DMG."
      ;;
    *)
      die "Finder styling failed — see $STYLE_LOG"
      ;;
  esac
fi

if [[ -f "$MOUNT_POINT/.DS_Store" ]]; then
  ok ".DS_Store committed (layout persisted)"
else
  die "no .DS_Store on the volume — the Finder layout did not persist"
fi

# The .DS_Store's window blob records the frame as "{{x, y}, {w, h}}".
EXPECT_FRAME="{$WINDOW_W, $(( WINDOW_H + TITLE_BAR_H ))}"
if grep -aq "$EXPECT_FRAME" "$MOUNT_POINT/.DS_Store"; then
  ok ".DS_Store window size is $EXPECT_FRAME (content ${WINDOW_W}x${WINDOW_H})"
else
  warn ".DS_Store does not record a $EXPECT_FRAME window — Finder may have overridden the bounds"
  warn "recorded: $(strings -a "$MOUNT_POINT/.DS_Store" | grep -o '{{[0-9, ]*}, {[0-9, ]*}}' | head -1)"
fi
if grep -aq 'background.tiff' "$MOUNT_POINT/.DS_Store"; then
  ok ".DS_Store references background.tiff"
else
  warn ".DS_Store has no background.tiff reference — the background may not show"
fi

# --- Force the Finder tab bar off ----------------------------------------
# Finder exposes no AppleScript property for the tab bar, and a window that
# inherits ShowTabView = True steals ~40pt of content height that TITLE_BAR_H
# never budgeted for — clipping the bottom of the background. Patch the
# persisted window blob directly, now that the AppleScript has closed the
# window and flushed .DS_Store, and before anything else touches the volume.
python3 "$DSSTORE_TOOL" patch "$MOUNT_POINT/.DS_Store" \
  || die "could not force ShowTabView off in $MOUNT_POINT/.DS_Store"
ok "ShowTabView forced off in .DS_Store"

# AppKit keeps its own app-global tab-bar switch, and it OUTRANKS the value in
# .DS_Store. If this build machine has Finder's tab bar turned on, the shipped
# DMG is still correct but it will look clipped *here*, which is exactly how
# this bug got mis-diagnosed once already. Say so rather than let the operator
# re-open that investigation.
if [[ "$(defaults read com.apple.finder \
         'NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow' 2>/dev/null)" == "1" ]]; then
  warn "this Mac has Finder's tab bar switched on globally (View > Hide Tab Bar)."
  warn "AppKit's setting overrides .DS_Store, so the window will show ~40pt of tab"
  warn "bar and clip the bottom of the background WHEN YOU OPEN IT HERE. The DMG"
  warn "itself is fine; a Finder with the default (hidden) tab bar renders it whole."
fi

# Volume icon — must come after Finder's update, which would otherwise delete it.
cp "$VOLICON" "$MOUNT_POINT/.VolumeIcon.icns"
[[ -f "$MOUNT_POINT/.VolumeIcon.icns" ]] || die "failed to copy .VolumeIcon.icns onto $MOUNT_POINT"
ok "copied .VolumeIcon.icns onto the volume"

if [[ -n "$SETFILE" ]]; then
  if ! "$SETFILE" -a C "$MOUNT_POINT" 2>/dev/null; then
    warn "SetFile -a C failed — the volume will use the generic disk icon"
  elif [[ -x /usr/bin/GetFileInfo ]] \
       && ! /usr/bin/GetFileInfo -a "$MOUNT_POINT" 2>/dev/null | grep -q 'C'; then
    warn "custom-icon flag did not stick — the volume will use the generic disk icon"
  else
    ok "custom volume icon flag set (SetFile -a C)"
  fi
fi

# Now that Finder has recorded positions under the real filename, hide the
# .webloc extension so it displays as "Visit the Website".
if [[ -n "$SETFILE" ]]; then
  "$SETFILE" -a E "$MOUNT_POINT/$WEBLOC_NAME" 2>/dev/null && ok "hid the .webloc extension (SetFile -a E)" \
    || warn "SetFile -a E failed on $WEBLOC_NAME — Finder may show the .webloc extension"
fi

chmod -Rf go-w "$MOUNT_POINT" 2>/dev/null || true
sync

hdiutil detach "$MOUNT_DEV" -quiet
MOUNT_DEV=""
ok "unmounted"

# ---------------------------------------------------------------------------
# 9. Convert to compressed read-only
# ---------------------------------------------------------------------------

step "Compressing"

rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"
ok "${FINAL_DMG#"$REPO_ROOT/"}"

# ---------------------------------------------------------------------------
# 10. Sign the DMG
# ---------------------------------------------------------------------------

step "Signing the DMG"

codesign --force --sign "$IDENTITY" --timestamp "$FINAL_DMG"
codesign --verify --verbose=2 "$FINAL_DMG" 2>&1 | sed 's/^/      /' \
  || die "codesign --verify failed for $FINAL_DMG"
ok "signed with: $IDENTITY"

# ---------------------------------------------------------------------------
# 11. Verify the layout of the FINAL image
# ---------------------------------------------------------------------------
#
# Everything up to here checked the read-write scratch image. This re-mounts
# what actually ships and asserts the window contract against it, so a Finder
# quirk that survives compression fails the build instead of the user's eyes.
# It runs before notarization so a broken layout never burns a submission.

LAYOUT_VERIFIED=0

step "Verifying final DMG layout"

[[ -d "/Volumes/$VOLUME_NAME" ]] \
  && die "a volume is already mounted at /Volumes/$VOLUME_NAME — cannot verify the final image"

VERIFY_OUT="$(hdiutil attach "$FINAL_DMG" -readonly -noverify -noautoopen -nobrowse)"
MOUNT_DEV="$(printf '%s\n' "$VERIFY_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
VERIFY_POINT="/Volumes/$VOLUME_NAME"
[[ -n "$MOUNT_DEV" ]] || die "could not attach $FINAL_DMG for verification"
[[ -d "$VERIFY_POINT" ]] || die "final DMG did not mount at $VERIFY_POINT"

[[ -f "$VERIFY_POINT/.DS_Store" ]] || die "the final DMG has no .DS_Store — the layout did not survive conversion"

EXPECT_FRAME_WH="${WINDOW_W}x$(( WINDOW_H + TITLE_BAR_H ))"
python3 "$DSSTORE_TOOL" verify "$VERIFY_POINT/.DS_Store" --frame "$EXPECT_FRAME_WH" \
  || die $'the shipped DMG\'s Finder window contract is wrong (see above).\n       Toolbar, sidebar and tab bar must all be off and the frame must be '"$EXPECT_FRAME_WH"$'.\n       A tab bar or toolbar steals content height and clips the background art.'
ok "window contract holds: frame $EXPECT_FRAME_WH, toolbar/sidebar/tab bar all off"

for required in "$APP_NAME" "Applications" "$WEBLOC_NAME" ".background/background.tiff" ".VolumeIcon.icns"; do
  [[ -e "$VERIFY_POINT/$required" ]] || die "final DMG is missing $required"
done
ok "contents present: app, Applications link, webloc, background, volume icon"

hdiutil detach "$MOUNT_DEV" -quiet
MOUNT_DEV=""
LAYOUT_VERIFIED=1

# ---------------------------------------------------------------------------
# 12. Notarize
# ---------------------------------------------------------------------------

NOTARIZED=0
STAPLED=0
NOTARY_MODE="none"
HAVE_CREDS=0
# Bash 3.2 + `set -u` errors on expanding an empty array, so seed it with a
# harmless first element and always keep at least one entry.
NOTARY_ARGS=(--no-progress)

if (( SKIP_NOTARIZE )); then
  NOTARY_MODE="skipped (--skip-notarize)"
elif [[ -n "$NOTARY_PROFILE_ARG" ]]; then
  NOTARY_MODE="keychain profile '$NOTARY_PROFILE_ARG' (--notary-profile)"
  NOTARY_ARGS+=(--keychain-profile "$NOTARY_PROFILE_ARG"); HAVE_CREDS=1
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_MODE="keychain profile '$NOTARY_PROFILE' (\$NOTARY_PROFILE)"
  NOTARY_ARGS+=(--keychain-profile "$NOTARY_PROFILE"); HAVE_CREDS=1
elif [[ -n "${AC_API_KEY_ID:-}" && -n "${AC_API_ISSUER_ID:-}" && -n "${AC_API_KEY_PATH:-}" ]]; then
  [[ -f "$AC_API_KEY_PATH" ]] || die "\$AC_API_KEY_PATH does not exist: $AC_API_KEY_PATH"
  NOTARY_MODE="App Store Connect API key $AC_API_KEY_ID"
  NOTARY_ARGS+=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID"); HAVE_CREDS=1
fi

if (( HAVE_CREDS )); then
  step "Notarizing ($NOTARY_MODE)"
  SUBMIT_LOG="$LOG_DIR/notarize-submit.log"
  set +e
  xcrun notarytool submit "$FINAL_DMG" "${NOTARY_ARGS[@]}" --wait 2>&1 | tee "$SUBMIT_LOG"
  NOTARY_RC=${PIPESTATUS[0]}
  set -e

  SUBMISSION_ID="$(grep -m1 -E '^[[:space:]]*id:' "$SUBMIT_LOG" | awk '{print $2}')"
  STATUS="$(grep -E '^[[:space:]]*status:' "$SUBMIT_LOG" | tail -1 | sed -E 's/.*status: *//')"

  if [[ "$STATUS" != "Accepted" || $NOTARY_RC -ne 0 ]]; then
    warn "notarization status: ${STATUS:-unknown}"
    if [[ -n "$SUBMISSION_ID" ]]; then
      printf '\n--- notarytool log %s ---\n' "$SUBMISSION_ID" >&2
      xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" >&2 2>&1 || true
    fi
    die "notarization was not accepted"
  fi

  ok "notarization accepted (submission $SUBMISSION_ID)"
  NOTARIZED=1

  xcrun stapler staple "$FINAL_DMG" | sed 's/^/      /'
  xcrun stapler validate "$FINAL_DMG" | sed 's/^/      /'
  STAPLED=1
  ok "stapled"
else
  if (( ! SKIP_NOTARIZE )); then
    NOTARY_MODE="none found"
    cat >&2 <<NOTARY

${C_YEL}${C_BOLD}WARNING: the DMG is signed but NOT notarized.${C_RESET}
Gatekeeper will refuse to open it on other Macs until it is.

No notarization credentials were found. Set one of these up, then either
re-run this script or notarize the existing DMG by hand:

  # one-time: store an app-specific password as a keychain profile
  xcrun notarytool store-credentials "AccessibilityMapper" \\
      --apple-id "<your-apple-id>" \\
      --team-id "$TEAM_ID" \\
      --password "<app-specific-password>"

  # then notarize + staple this DMG
  xcrun notarytool submit "$FINAL_DMG" --keychain-profile "AccessibilityMapper" --wait
  xcrun stapler staple "$FINAL_DMG"
  xcrun stapler validate "$FINAL_DMG"
  spctl -a -t open --context context:primary-signature -vv "$FINAL_DMG"

  # or re-run the whole pipeline with credentials:
  $0 --notary-profile "AccessibilityMapper"

NOTARY
  fi
fi

# ---------------------------------------------------------------------------
# 13. Summary
# ---------------------------------------------------------------------------

step "Gatekeeper assessment"
SPCTL_OUT="$(spctl -a -t open --context context:primary-signature -vv "$FINAL_DMG" 2>&1 || true)"
printf '%s\n' "$SPCTL_OUT" | sed 's/^/      /'
SPCTL_SUMMARY="$(printf '%s\n' "$SPCTL_OUT" | tr '\n' ' ' | sed 's/  */ /g')"

DMG_SIZE="$(ls -lh "$FINAL_DMG" | awk '{print $5}')"

cat <<SUMMARY

$C_BOLD────────────────────────────────────────────────────────────────$C_RESET
$C_BOLD  Accessibility Mapper — DMG build summary$C_RESET
$C_BOLD────────────────────────────────────────────────────────────────$C_RESET
  Output        : $FINAL_DMG
  Size          : $DMG_SIZE
  Version       : $VERSION (build $BUILD_NUM)
  Archive style : $ARCHIVE_STYLE signing
  Export method : $EXPORT_METHOD
  Identity      : $IDENTITY
  Finder layout : $( ((STYLED)) && echo "applied (${WINDOW_W}x${WINDOW_H}, icons $ICON_SIZE)" || echo "NOT applied" )
  Layout verified: $( ((LAYOUT_VERIFIED)) && echo "yes (frame $EXPECT_FRAME_WH, no toolbar/sidebar/tab bar)" || echo NO )
  Notarization  : $NOTARY_MODE
  Notarized     : $( ((NOTARIZED)) && echo yes || echo NO )
  Stapled       : $( ((STAPLED)) && echo yes || echo NO )
  spctl         : $SPCTL_SUMMARY
$C_BOLD────────────────────────────────────────────────────────────────$C_RESET

SUMMARY

exit 0
