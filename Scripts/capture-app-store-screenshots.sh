#!/usr/bin/env bash
#
# capture-app-store-screenshots.sh
#
# Deterministically captures the seven App Store source screenshots from the
# DEBUG-only visual-QA routes (see Docs/app-store-screenshot-plan.md). It only
# drives launch arguments that are compiled `#if DEBUG`; nothing here ships in
# Release. Generated PNGs are local artifacts (not committed).
#
#   ./Scripts/capture-app-store-screenshots.sh [--device <UDID>] [--output <dir>] [--force]
#
# Defaults: a booted simulator (or PULSECUE_SIM_DEST UDID), output ./build/app-store-screenshots.
#
set -uo pipefail

PROJECT="Pulse Cue.xcodeproj"
SCHEME="Pulse Cue"
BUNDLE_ID="com.kounishiyuuki.pulsecue"
ROUTE_ARG="-pulsecue-debug-glass-ui-route"
HOME_ARG="-pulsecue-ui-test-custom-machine-flow"

DEVICE=""
OUTPUT="build/app-store-screenshots"
FORCE=0
FORMGUIDE_DELAY="${PULSECUE_FORMGUIDE_DELAY:-3}"  # extra settle only for RealityKit
SETTLE="${PULSECUE_SETTLE:-4}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

# 1. Prerequisites
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found"
[ -d "$PROJECT" ] || fail "run from the repository root ($PROJECT not found)"

# 2. Device: explicit UDID, else the currently booted simulator.
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["devices"];print(next((x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"),""))' 2>/dev/null)
fi
[ -n "$DEVICE" ] || fail "no --device UDID and no booted simulator"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" 2>/dev/null
info "Device: $DEVICE"

# 3. Build + install Debug
info "Building Debug app…"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$DEVICE" -configuration Debug CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1 \
  || fail "Debug build failed"
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pulse_Cue-*/Build/Products/Debug-iphonesimulator/"Pulse Cue.app" 2>/dev/null | head -1)
[ -n "$APP" ] || fail "built app not found"
xcrun simctl install "$DEVICE" "$APP" || fail "install failed"

# 4. Deterministic presentation: light appearance + clean status bar.
xcrun simctl ui "$DEVICE" appearance light >/dev/null 2>&1 || true
xcrun simctl ui "$DEVICE" content_size medium >/dev/null 2>&1 || true
xcrun simctl status_bar "$DEVICE" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true

mkdir -p "$OUTPUT"

# route mapping: filename | launch args (route or custom-machine-flow for home)
capture() {
  local file="$1"; shift
  local path="$OUTPUT/$file"
  if [ -e "$path" ] && [ "$FORCE" -ne 1 ]; then
    fail "$path exists (use --force to overwrite)"
  fi
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "$@" >/dev/null 2>&1 || fail "launch failed for $file"
  # Readiness: bounded settle. Form Guide gets extra time for RealityKit.
  local wait="$SETTLE"
  case "$file" in *form-guide*) wait=$((SETTLE + FORMGUIDE_DELAY));; esac
  sleep "$wait"
  xcrun simctl io "$DEVICE" screenshot "$path" >/dev/null 2>&1 || fail "screenshot failed for $file"
  printf '  captured %s\n' "$file"
}

info "Capturing…"
capture "01-home.png"           "$HOME_ARG"
capture "02-weekly-plan.png"    "$ROUTE_ARG" "preview-weekly"
capture "03-runner-active.png"  "$ROUTE_ARG" "runner-active"
capture "04-runner-rest.png"    "$ROUTE_ARG" "runner-rest"
capture "05-history-detail.png" "$ROUTE_ARG" "history-detail"
capture "06-my-gym.png"         "$ROUTE_ARG" "mygym-active"
capture "07-form-guide.png"     "$ROUTE_ARG" "form-guide"

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl status_bar "$DEVICE" clear >/dev/null 2>&1 || true

info "Done. Output: $OUTPUT"
echo "Review each image manually before use (see Docs/app-store-screenshot-plan.md checklist)."
