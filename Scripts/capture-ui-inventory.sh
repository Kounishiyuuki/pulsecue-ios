#!/usr/bin/env bash
#
# capture-ui-inventory.sh
#
# Deterministic DEBUG-only UI inventory capture for design review / Stitch.
# Reuses the PR #143 GlassUI visual-QA routes (all `#if DEBUG`). Generated
# images are LOCAL artifacts under an ignored build dir — never committed.
#
#   ./Scripts/capture-ui-inventory.sh [--device <UDID>] [--output <dir>] \
#       [--variant light|dark|all] [--group <NN>] [--all] [--force]
#
# Slice 1 covers the screens reachable via existing routes. Runner/My Gym/
# Planner/Library extra states and light/dark/narrow variants arrive in later
# slices (see Docs/ui-inventory.md).
#
set -uo pipefail

PROJECT="Pulse Cue.xcodeproj"
SCHEME="Pulse Cue"
BUNDLE_ID="com.kounishiyuuki.pulsecue"
ROUTE_ARG="-pulsecue-debug-glass-ui-route"
SCREENSHOT_DEFAULTS_DOMAIN="com.pulsecue.screenshot-visualqa"

DEVICE=""
OUTPUT="build/ui-inventory"
VARIANT="light"
GROUP=""
FORCE=0
SETTLE="${PULSECUE_SETTLE:-4}"
FORMGUIDE_DELAY="${PULSECUE_FORMGUIDE_DELAY:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --all) shift ;;                    # accepted for symmetry; default is all
    --force) FORCE=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$1"; }

command -v xcrun >/dev/null 2>&1 || fail "xcrun not found"
[ -d "$PROJECT" ] || fail "run from the repository root ($PROJECT not found)"

if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["devices"];print(next((x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"),""))' 2>/dev/null)
fi
[ -n "$DEVICE" ] || fail "no --device UDID and no booted simulator"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" 2>/dev/null
info "Device: $DEVICE  Variant: $VARIANT"

cleanup() {
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$DEVICE" clear >/dev/null 2>&1 || true
  xcrun simctl spawn "$DEVICE" defaults delete "$SCREENSHOT_DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "Building Debug app…"
xcodebuild build -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$DEVICE" -configuration Debug CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1 \
  || fail "Debug build failed"
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Pulse_Cue-*/Build/Products/Debug-iphonesimulator/"Pulse Cue.app" 2>/dev/null | head -1)
[ -n "$APP" ] || fail "built app not found"
xcrun simctl install "$DEVICE" "$APP" || fail "install failed"

apply_appearance() {
  xcrun simctl ui "$DEVICE" appearance "$1" >/dev/null 2>&1 || true
  xcrun simctl ui "$DEVICE" content_size medium >/dev/null 2>&1 || true
  xcrun simctl status_bar "$DEVICE" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
}

# group | filename-stem | route
ROUTES="
01-onboarding|onboarding|onboarding
02-auth|login|login
03-home|home|home
05-planner|target-body-part|planner
05-planner|preview-single|preview-single
05-planner|weekly-before-generation|preview-weekly-before-generation
05-planner|weekly-candidate|preview-weekly
05-planner|unavailable-target|planner-unavailable-target
06-runner|runner-active|runner-active
06-runner|runner-active-later-set|runner-active-later-set
06-runner|runner-rest|runner-rest
07-history|history-populated|history-populated
07-history|history-detail|history-detail
08-my-gym|mygym-active|mygym-active
08-my-gym|mygym-empty|mygym-empty
08-my-gym|mygym-multiple|mygym-multiple
08-my-gym|machine-selection|machine-selection
08-my-gym|machine-selection-none-selected|machine-selection-none-selected
08-my-gym|custom-machine-add|custom-machine-add
08-my-gym|custom-machine-edit|custom-machine-edit
09-library|exercise-library|exercise-library
09-library|search-results|exercise-library-search-results
09-library|search-no-results|exercise-library-no-results
10-form-guide|form-guide|form-guide
10-form-guide|form-guide-instructions-expanded|form-guide-instructions-expanded
"

capture_one() {
  local outdir="$1" stem="$2" route="$3" suffix="$4"
  local path="$outdir/${stem}${suffix}.png"
  if [ -e "$path" ] && [ "$FORCE" -ne 1 ]; then
    fail "$path exists (use --force to overwrite)"
  fi
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "$ROUTE_ARG" "$route" >/dev/null 2>&1 \
    || fail "launch failed for $route"
  local wait="$SETTLE"
  case "$route" in *form-guide*) wait=$((SETTLE + FORMGUIDE_DELAY));; esac
  sleep "$wait"
  xcrun simctl io "$DEVICE" screenshot "$path" >/dev/null 2>&1 || fail "screenshot failed for $route"
  printf '  %s\n' "${path#"$OUTPUT"/}"
}

run_variant() {
  local appearance="$1" suffix="$2"
  apply_appearance "$appearance"
  echo "$ROUTES" | while IFS='|' read -r grp stem route; do
    [ -z "$grp" ] && continue
    [ -n "$GROUP" ] && [ "$grp" != "$GROUP" ] && continue
    local outdir="$OUTPUT/$grp"
    mkdir -p "$outdir"
    capture_one "$outdir" "$stem" "$route" "$suffix"
  done
}

info "Capturing…"
case "$VARIANT" in
  light) run_variant light "" ;;
  dark)  run_variant dark "-dark" ;;
  all)   run_variant light ""; run_variant dark "-dark" ;;
  *) fail "unknown --variant: $VARIANT" ;;
esac

info "Done. Output: $OUTPUT"
echo "Review every image manually (see Docs/ui-inventory.md). Generated images are not committed."
